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

# 2. Enforce every environment. With the AAP executor the push above may start
# an apply job that ends early (only fleet/ changed) or none at all (main was
# already at baseline), and a job still queued from an earlier merge would
# rewrite the drift ConfigMap after we delete it. So: let the queue drain,
# delete the ConfigMap, then launch one full apply run ourselves and wait for
# exactly that job.
APPLY_JOB=""
if [ "${SATELLITE_EXECUTOR}" = "aap" ] && [ "${DRY}" != true ]; then
  SAT_TPL_Q=$(python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${SAT_APPLY_TEMPLATE}")
  log "Waiting for queued or running apply jobs to finish"
  for _ in $(seq 1 120); do
    busy=$(aap_api "/jobs/?name=${SAT_TPL_Q}&status__in=new,pending,waiting,running&page_size=1" 2>/dev/null \
      | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("count", 0))' 2>/dev/null || echo 0)
    [ "${busy}" = "0" ] && break
    sleep 5
  done
fi
run oc delete configmap satellite-cac-applied -n "${NAMESPACE}" --ignore-not-found
run argocd_refresh rhel-fleet
[ "${SATELLITE_EXECUTOR}" = "argo" ] && run argocd_refresh satellite-config
if [ "${SATELLITE_EXECUTOR}" = "aap" ] && [ "${DRY}" != true ]; then
  TID=$(aap_api "/job_templates/?name=${SAT_TPL_Q}" | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["results"]; print(r[0]["id"] if r else "")')
  [ -n "${TID}" ] || die "job template '${SAT_APPLY_TEMPLATE}' not found in AAP (bootstrap.sh aapconfig)"
  APPLY_JOB=$(curl_aap -sSk --max-time 60 -H 'Content-Type: application/json' -X POST -d '{"extra_vars": {}}' \
    "$(aap_url)/api/controller/v2/job_templates/${TID}/launch/" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("job", ""))')
  [ -n "${APPLY_JOB}" ] && log "  launched full apply run: AAP job ${APPLY_JOB}" || warn "could not launch ${SAT_APPLY_TEMPLATE}"
fi

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

# 5. Wait for the apply run, then bring lc-* packages back to what they are served
if [ "${DRY}" != true ] && [ -n "${APPLY_JOB}" ]; then
  log "Waiting up to 10 min for AAP job ${APPLY_JOB} (${SAT_APPLY_TEMPLATE})"
  rc=2
  for _ in $(seq 1 120); do
    st=$(aap_api "/jobs/${APPLY_JOB}/" 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null || true)
    case "${st}" in successful) rc=0; break ;; failed|error|canceled) rc=1; break ;; esac
    sleep 5
  done
  case "${rc}" in
    0) log "  apply run succeeded" ;;
    1) warn "apply run failed: $(aap_url)/execution/jobs/playbook/${APPLY_JOB}/output" ;;
    *) warn "apply run not finished yet: $(aap_url)/execution/jobs/playbook/${APPLY_JOB}/output" ;;
  esac
elif [ "${DRY}" != true ]; then
  log "Waiting up to 10 min for the Satellite apply run started after ${SINCE} ($(satellite_apply_where))"
  if wait_satellite_apply "${SINCE}" 600; then rc=0; else rc=$?; fi
  case "${rc}" in
    0) log "  apply run succeeded" ;;
    1) warn "apply run failed: $(satellite_apply_where)" ;;
    *) warn "no finished apply run yet: $(satellite_apply_where)" ;;
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
