#!/bin/bash
# Return the GitOps demo to its starting state, so it can be run again.
#
# Usage: gitops/scripts/reset.sh [--dry-run]
#        gitops/scripts/reset.sh --save-baseline   record the current Git releases.yml as baseline
#
# What it does:
#   1. One commit on main (history kept, no force push): the repo tree becomes
#      gitops/repo again; all other branches are deleted (no fleet/ servers, structure.yml without demo
#      additions such as Patch-Wave-3) and releases.yml gets the baseline versions.
#   2. Drops ConfigMap satellite-cac-applied, so the next Job enforces every
#      environment (also undoes UI promotions that were never recorded).
#   3. Argo CD prunes the Git-managed VMs; VMs created by hand (V1, label
#      role=fleet) are deleted directly.
#   4. Deletes those hosts in Satellite and host collections Patch-Wave-N that
#      structure.yml no longer declares.
#   5. Waits for the satellite-cac Job, then distro-syncs RESET_PACKAGES
#      (default: demo-app) on lc-dev/lc-qa/lc-prod back to what their
#      environment serves.
#   6. Prints the next publish-version.sh version.
#
# Baseline: ~/.cache/satellite-demo/gitops-baseline (written by bootstrap.sh seed,
# or by --save-baseline).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

DRY=false; SAVE=false
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=true ;;
    --save-baseline) SAVE=true ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown argument: $a" ;;
  esac
done
require_cmd git oc
: "${RESET_PACKAGES:=demo-app}"
BASELINE_FILE="${CACHE_DIR}/gitops-baseline"
REMOTE="https://${GITEA_USER}:$(gitea_token)@$(gitea_host)/${GITEA_USER}/${GITEA_REPO}.git"
export GIT_SSL_NO_VERIFY=true
REL="satellite/releases.yml"
run() { if [ "${DRY}" = true ]; then echo "  [dry-run] $*"; else "$@"; fi; }

if [ -d "${FLEET_CLONE_DIR}/.git" ]; then
  git -C "${FLEET_CLONE_DIR}" remote set-url origin "${REMOTE}"
  git -C "${FLEET_CLONE_DIR}" fetch -q --prune origin
  git -C "${FLEET_CLONE_DIR}" checkout -q -f -B main origin/main
  git -C "${FLEET_CLONE_DIR}" clean -qfdx
else
  mkdir -p "$(dirname "${FLEET_CLONE_DIR}")"
  git clone -q "${REMOTE}" "${FLEET_CLONE_DIR}"
fi
declared() { sed -nE "s/^  $1: \"?([0-9.]+)\"?.*/\\1/p" "${FLEET_CLONE_DIR}/${REL}"; }

if [ "${SAVE}" = true ]; then
  mkdir -p "${CACHE_DIR}"
  echo "Dev=$(declared Dev) QA=$(declared QA) Prod=$(declared Prod)" > "${BASELINE_FILE}"
  log "Baseline saved: $(cat "${BASELINE_FILE}")"
  exit 0
fi
[ -s "${BASELINE_FILE}" ] || die "no baseline at ${BASELINE_FILE} (run: reset.sh --save-baseline in the start state)"
BASELINE=$(cat "${BASELINE_FILE}")
log "Baseline: ${BASELINE}"

# Servers to remove: everything with role=fleet (Git-managed and V1 by hand).
mapfile -t FLEET_VMS < <(oc get vm -n "${NAMESPACE}" -l role=fleet -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
log "Fleet VMs: ${FLEET_VMS[*]:-(none)}"

# Jobs created after this moment belong to this reset (the push below
# already triggers one, so take the time before pushing).
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 1. Git: tree = gitops/repo + baseline releases
log "Git: reset main to gitops/repo with baseline releases"
cd "${FLEET_CLONE_DIR}"
git rm -rq --ignore-unmatch . >/dev/null
cp -a "${GITOPS_DIR}/repo/." .
for kv in ${BASELINE}; do
  sed -i -E "s|^(  ${kv%%=*}: ).*|\\1\"${kv#*=}\"|" "${REL}"
done
git add -A
if git diff --cached --quiet; then
  log "  main already at baseline"
else
  git --no-pager diff --cached --stat | sed 's/^/  /'
  if [ "${DRY}" = true ]; then
    echo "  [dry-run] would commit and push 'Reset demo to baseline'"
    git reset -q --hard origin/main
  else
    git -c user.name="GitOps Demo" -c user.email="${GITEA_USER}@example.com" \
      commit -q -m "Reset demo to baseline" -m "Baseline releases: ${BASELINE}"
    git push -q origin main
  fi
fi

# 1b. Delete every branch except main: merged PR branches stay behind when a
# PR is merged in the UI, and a leftover add-<name> branch makes the next
# request for <name> fail ("branch already exists").
for b in $(gitea_api GET "/repos/${GITEA_USER}/${GITEA_REPO}/branches?limit=100" \
             | python3 -I -c 'import json,sys; print(" ".join(x["name"] for x in json.load(sys.stdin) if x["name"] != "main"))'); do
  run gitea_api DELETE "/repos/${GITEA_USER}/${GITEA_REPO}/branches/${b}" >/dev/null && log "  deleted branch ${b}"
done

# 2. Enforce every environment on the next run
run oc delete configmap satellite-cac-applied -n "${NAMESPACE}" --ignore-not-found
run argocd_refresh rhel-fleet satellite-config

# 3. VMs
if [ ${#FLEET_VMS[@]} -gt 0 ]; then
  log "Waiting up to 3 min for Argo CD to prune Git-managed VMs"
  for _ in $(seq 1 36); do
    [ "${DRY}" = true ] && break
    left=$(oc get vm -n "${NAMESPACE}" -l role=fleet,fleet.demo/provisioned-by!=manual -o name 2>/dev/null | wc -l)
    [ "${left}" -eq 0 ] && break
    sleep 5
  done
  for vm in "${FLEET_VMS[@]}"; do
    run oc delete vm "${vm}" -n "${NAMESPACE}" --ignore-not-found --wait=false
  done
fi

# 4. Satellite: hosts and undeclared patch waves
log "Satellite: removing fleet hosts"
HOSTS=$(sat_hammer '--csv --no-headers host list --organization Demo_Org --fields Name' 2>/dev/null | tr -d '\r' || true)
for vm in "${FLEET_VMS[@]}"; do
  for h in $(grep -E "^${vm}(\.|$)" <<<"${HOSTS}" || true); do
    log "  host ${h}"
    run sat_hammer "host delete --name ${h} --organization Demo_Org" >/dev/null || warn "could not delete host ${h}"
  done
done
DECLARED_HC=$(sed -nE 's/^  - name: (Patch-Wave-[0-9]+).*/\1/p' "${GITOPS_DIR}/repo/satellite/structure.yml")
for hc in $(sat_hammer '--csv --no-headers host-collection list --organization Demo_Org --fields Name' 2>/dev/null | tr -d '\r' | grep -E '^Patch-Wave-[0-9]+$' || true); do
  grep -qx "${hc}" <<<"${DECLARED_HC}" && continue
  log "  host collection ${hc} (not in structure.yml)"
  run sat_hammer "host-collection delete --name ${hc} --organization Demo_Org" >/dev/null || warn "could not delete ${hc}"
done

# 5. Wait for the Job, then bring lc-* packages back to what they are served
if [ "${DRY}" != true ]; then
  log "Waiting up to 10 min for the satellite-cac Job started after ${SINCE}"
  ok=""
  for _ in $(seq 1 120); do
    created=$(oc get job satellite-cac -n "${NAMESPACE}" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)
    if [ -n "${created}" ] && [[ ! "${created}" < "${SINCE}" ]]; then
      s=$(oc get job satellite-cac -n "${NAMESPACE}" -o jsonpath='{.status.succeeded}{"/"}{.status.failed}' 2>/dev/null)
      case "$s" in 1/*) ok=yes; break ;; */1) ok=no; break ;; esac
    fi
    sleep 5
  done
  case "${ok}" in
    yes) log "  Job succeeded" ;;
    no)  warn "Job failed: oc logs -n ${NAMESPACE} job/satellite-cac" ;;
    *)   warn "Job not finished yet; check Argo CD satellite-config (Sync if needed)" ;;
  esac
fi
for vm in lc-dev lc-qa lc-prod; do
  oc get vmi "${vm}" -n "${NAMESPACE}" >/dev/null 2>&1 || continue
  log "  ${vm}: dnf distro-sync ${RESET_PACKAGES}"
  run run_on_vm "${vm}" "sudo dnf -q clean expire-cache >/dev/null; sudo dnf -q -y distro-sync ${RESET_PACKAGES} >/dev/null 2>&1; rpm -q ${RESET_PACKAGES} | tr '\n' ' '" || warn "${vm}: distro-sync failed"
  echo
done

# 6. Next version
LATEST=$(satellite_latest_version || true)
APP=$(sat_hammer '--csv --no-headers package list --repository demo-app-rpms --product Demo-App --organization Demo_Org --fields Filename' 2>/dev/null \
  | tr -d '\r' | sed -nE 's/^demo-app-([0-9.]+)-.*/\1/p' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)
APP_MAJOR="${APP%%.*}"; [[ "${APP_MAJOR}" =~ ^[0-9]+$ ]] || APP_MAJOR=0
cat <<EOF

Reset done. Start state:
  releases.yml   ${BASELINE}
  fleet VMs      none (V1/V2/V3 servers removed, hosts deleted in Satellite)
  newest CV      RHEL9-FullStack ${LATEST:-?} (in Library)
  demo-app       newest RPM ${APP:-?} in Satellite
Next: gitops/scripts/publish-version.sh $(( ${APP_MAJOR:-0} + 1 )).0
EOF
