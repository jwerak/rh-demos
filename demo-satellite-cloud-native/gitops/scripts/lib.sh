#!/bin/bash
# Shared helpers for the gitops/ scripts. Source, do not execute.
#
# Profile selection mirrors scripts/demo-scenarios.sh: DEMO_ENV_FILE picks the
# env file, relative paths resolve against the demo root. The GitOps flow only
# exists on the OpenShift profile, so the default is .env.ocp.

GITOPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_ROOT="$(cd "${GITOPS_DIR}/.." && pwd)"

: "${DEMO_ENV_FILE:=.env.ocp}"
case "${DEMO_ENV_FILE}" in
  /*) DEMO_ENV_PATH="${DEMO_ENV_FILE}" ;;
  *)  DEMO_ENV_PATH="${DEMO_ROOT}/${DEMO_ENV_FILE}" ;;
esac
if [ ! -f "${DEMO_ENV_PATH}" ]; then
  echo "ERROR: env file not found: ${DEMO_ENV_PATH}" >&2
  echo "       Create it first (see gitops/README.md, 'Env file')." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${DEMO_ENV_PATH}"
export DEMO_ENV_FILE

: "${DEMO_PASSWORD:?DEMO_PASSWORD not set in ${DEMO_ENV_PATH}}"
: "${SAT_FQDN:?SAT_FQDN not set in ${DEMO_ENV_PATH}}"
if [ "${DEMO_PLATFORM:-openshift}" != "openshift" ]; then
  echo "ERROR: gitops/ needs DEMO_PLATFORM=openshift (got ${DEMO_PLATFORM})." >&2
  exit 1
fi
export DEMO_PLATFORM=openshift

NAMESPACE="satellite-cloud-native"
FLEET_ENVS="dev qa prod"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -o LogLevel=ERROR"
# run_on_vm / run_on_vm_sudo (virtctl port-forward + sshpass), functions only
# shellcheck disable=SC1091
source "${DEMO_ROOT}/scripts/platform-openshift.sh"

# hammer on the Satellite VM. Arguments are passed through one level of
# shell; keep them free of single quotes.
sat_hammer() {
  run_on_vm satellite "sudo hammer $*"
}

# Gitea (in-cluster Git server for the demo)
: "${GITEA_NS:=gitea}"
: "${GITEA_USER:=gitops}"
: "${GITEA_PASSWORD:=${DEMO_PASSWORD}}"
: "${GITEA_REPO:=rhel-fleet}"
GITEA_INTERNAL_URL="http://gitea.${GITEA_NS}.svc.cluster.local:3000"
GITEA_REPO_URL_INTERNAL="${GITEA_INTERNAL_URL}/${GITEA_USER}/${GITEA_REPO}.git"

# Satellite API URL for the in-cluster Job. It must be the name clients use
# (SAT_FQDN): Satellite builds the registration command from the URL the API
# was called with, and a command pointing at the service name fails on the
# host with "no alternative certificate subject name matches". The Job reaches
# SAT_FQDN through the router (passthrough route).
: "${SATELLITE_API_URL:=https://${SAT_FQDN}}"

# Who applies satellite/ after a merge: "aap" (EDA rulebook -> job template
# "SAT · Apply Satellite as code", default) or "argo" (Argo CD app
# satellite-config with a PostSync Job, the fallback).
: "${SATELLITE_EXECUTOR:=aap}"

# Ansible Automation Platform on the same cluster (bootstrap.sh aap / aapconfig)
: "${AAP_NS:=aap}"
: "${AAP_NAME:=aap}"
# Optional: subscription manifest ZIP to activate AAP without the UI.
: "${AAP_MANIFEST:=}"

CACHE_DIR="${HOME}/.cache/satellite-demo"
AAP_PASSWORD_FILE="${CACHE_DIR}/aap-admin-password"
GITEA_TOKEN_FILE="${CACHE_DIR}/gitea-token"
FLEET_CLONE_DIR="${CACHE_DIR}/${GITEA_REPO}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing command: $c"; done
}

gitea_host() {
  oc get route gitea -n "${GITEA_NS}" -o jsonpath='{.spec.host}' 2>/dev/null
}

gitea_url() {
  local h
  h="$(gitea_host)"
  [ -n "$h" ] || die "Gitea route not found in namespace ${GITEA_NS} (run bootstrap.sh gitea)"
  echo "https://${h}"
}

aap_host() {
  local h
  h=$(oc get route "${AAP_NAME}" -n "${AAP_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  # Fall back to any route that is not the controller's own (the gateway is the entry point).
  [ -n "$h" ] || h=$(oc get route -n "${AAP_NS}" -o jsonpath='{range .items[*]}{.metadata.name} {.spec.host}{"\n"}{end}' 2>/dev/null \
    | awk '$1 !~ /controller|eda|hub/ {print $2; exit}')
  echo "$h"
}

aap_url() {
  local h
  h="$(aap_host)"
  [ -n "$h" ] || die "AAP route not found in namespace ${AAP_NS} (run bootstrap.sh aap)"
  echo "https://${h}"
}

aap_password() {
  [ -s "${AAP_PASSWORD_FILE}" ] || die "no AAP admin password at ${AAP_PASSWORD_FILE} (run bootstrap.sh aap)"
  cat "${AAP_PASSWORD_FILE}"
}

gitea_token() {
  [ -s "${GITEA_TOKEN_FILE}" ] || die "no Gitea token at ${GITEA_TOKEN_FILE} (run bootstrap.sh gitea)"
  cat "${GITEA_TOKEN_FILE}"
}

# Credentials go to curl through a config on a file descriptor (-K <(...)),
# never on the command line where `ps` shows them.
_curl_cfg_quote() { python3 -I -c 'import sys; print(sys.argv[1].replace("\\", "\\\\").replace("\"", "\\\""))' "$1"; }
curl_aap() { curl -K <(printf 'user = "admin:%s"\n' "$(_curl_cfg_quote "$(aap_password)")") "$@"; }
curl_gitea() { curl -K <(printf 'header = "Authorization: token %s"\n' "$(_curl_cfg_quote "$(gitea_token)")") "$@"; }

# gitea_api METHOD PATH [JSON]  -> prints body, returns non-zero on HTTP >= 400
gitea_api() {
  local method="$1" path="$2" data="${3:-}"
  local url
  url="$(gitea_url)/api/v1${path}"
  if [ -n "${data}" ]; then
    curl_gitea -sSk --fail-with-body -X "${method}" -H 'Content-Type: application/json' -d "${data}" "${url}"
  else
    curl_gitea -sSk --fail-with-body -X "${method}" "${url}"
  fi
}

# Size presets shared by the V1 helper; the Jinja template carries the same table.
size_cores()  { case "$1" in small) echo 1 ;; medium) echo 2 ;; large) echo 4 ;; *) return 1 ;; esac; }
size_memory() { case "$1" in small) echo 2Gi ;; medium) echo 4Gi ;; large) echo 8Gi ;; *) return 1 ;; esac; }

valid_server_name() {
  [[ "$1" =~ ^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$ ]]
}

# render_vm NAME ENV SIZE PROVISIONED_BY OUTFILE
# Renders gitops/repo/templates/vm.yaml.j2 with Ansible's template engine,
# the same one AAP uses, so V1, V2 and V3 produce identical manifests.
render_vm() {
  local name="$1" env="$2" size="$3" by="$4" out="$5"
  valid_server_name "${name}" || die "invalid server name '${name}' (lowercase, digits, '-', max 40)"
  case "${env}" in dev|qa|prod) ;; *) die "environment must be dev, qa or prod" ;; esac
  size_cores "${size}" >/dev/null || die "size must be small, medium or large"
  require_cmd ansible
  ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
  ANSIBLE_DEPRECATION_WARNINGS=False ANSIBLE_PYTHON_INTERPRETER=auto_silent ansible localhost -c local -m ansible.builtin.template \
    -a "src=${GITOPS_DIR}/repo/templates/vm.yaml.j2 dest=${out}" \
    -e "server_name=${name} lifecycle_env=${env} server_size=${size} provisioned_by=${by}" \
    -e "requested_by=${USER:-presenter}" >/dev/null \
    || die "template rendering failed"
}

# Versions of RHEL9-FullStack each lifecycle environment serves in Satellite
# right now, as "Dev=3.0 QA=2.0 Prod=2.0". Non-zero when c1 has not run.
satellite_releases() {
  local out
  out=$(sat_hammer '--csv --no-headers content-view version list --content-view RHEL9-FullStack --organization Demo_Org --fields "Version,Lifecycle Environments"' 2>/dev/null) || return 1
  python3 -I -c '
import csv, sys
env = {}
for r in csv.reader(sys.stdin):
    if len(r) < 2: continue
    for e in r[1].split(","):
        e = e.strip()
        if e in ("Dev", "QA", "Prod"): env[e] = r[0].strip()
if len(env) != 3: sys.exit(1)
print(" ".join(f"{k}={env[k]}" for k in ("Dev", "QA", "Prod")))
' <<<"${out}"
}

# Newest RHEL9-FullStack version (what a fresh publish produced).
satellite_latest_version() {
  sat_hammer '--csv --no-headers content-view version list --content-view RHEL9-FullStack --organization Demo_Org --fields Version' 2>/dev/null \
    | tr -d '\r' | sort -t. -k1,1n -k2,2n | tail -1
}

# Normalise dev/qa/prod (any case) to the Satellite names Dev/QA/Prod.
lce_name() {
  case "${1,,}" in dev) echo Dev ;; qa) echo QA ;; prod) echo Prod ;; *) return 1 ;; esac
}

# gitea_pr BRANCH TITLE BODY -> PR number. Re-uses an open PR for the branch
# (the presenter may already have opened it in the UI).
gitea_pr() {
  local branch="$1" title="$2" body="$3" num
  num=$(gitea_api GET "/repos/${GITEA_USER}/${GITEA_REPO}/pulls?state=open&limit=50" \
    | python3 -I -c 'import json,sys; b=sys.argv[1]; print(next((str(p["number"]) for p in json.load(sys.stdin) if p["head"]["ref"]==b), ""))' "${branch}")
  if [ -z "${num}" ]; then
    num=$(gitea_api POST "/repos/${GITEA_USER}/${GITEA_REPO}/pulls" \
      "$(python3 -I -c 'import json,sys; print(json.dumps({"title":sys.argv[1],"head":sys.argv[2],"base":"main","body":sys.argv[3]}))' "${title}" "${branch}" "${body}")" \
      | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["number"])')
  fi
  echo "${num}"
}

# gitea_merge NUMBER. Gitea answers 405 while it is still computing
# mergeability of a fresh PR, so retry for up to ~30 s.
gitea_merge() {
  local i
  for i in $(seq 1 10); do
    gitea_api POST "/repos/${GITEA_USER}/${GITEA_REPO}/pulls/$1/merge" \
      '{"Do":"merge","delete_branch_after_merge":true}' >/dev/null 2>&1 && return 0
    gitea_api GET "/repos/${GITEA_USER}/${GITEA_REPO}/pulls/$1" 2>/dev/null | grep -q '"merged":true' && return 0
    sleep 3
  done
  die "could not merge PR #$1 (open it in Gitea)"
}

# Ask Argo CD to re-read Git now instead of waiting for webhook/polling.
argocd_refresh() {
  local app
  for app in "$@"; do
    oc annotate applications.argoproj.io "${app}" -n openshift-gitops \
      argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
  done
}

# --- Who applies satellite/ (SATELLITE_EXECUTOR): AAP job or Argo CD Job ---
SAT_APPLY_TEMPLATE="SAT · Apply Satellite as code"

# aap_api PATH -> JSON from the controller API (admin, basic auth)
aap_api() {
  curl_aap -sSk --max-time 30 "$(aap_url)/api/controller/v2$1"
}

# Latest apply run as "<created-UTC> <status>"; status is one of
# pending/waiting/running/successful/failed/error/canceled.
satellite_apply_last() {
  if [ "${SATELLITE_EXECUTOR}" = "aap" ]; then
    aap_api "/jobs/?name=$(python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${SAT_APPLY_TEMPLATE}")&order_by=-id&page_size=1" 2>/dev/null \
      | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["results"]; print("%sZ %s %s" % (r[0]["created"][:19], r[0]["status"], r[0]["id"]) if r else "")'
  else
    local j
    j=$(oc get job satellite-cac -n "${NAMESPACE}" -o jsonpath='{.metadata.creationTimestamp} {.status.succeeded}/{.status.failed}' 2>/dev/null) || return 0
    case "$j" in *" 1/"*) echo "${j%% *} successful" ;; *"/1") echo "${j%% *} failed" ;; ?*) echo "${j%% *} running" ;; esac
  fi
}

# Is an apply run in progress right now? (Argo CD skips commits merged during
# a run; AAP queues them, so this only matters for the argo executor.)
satellite_apply_busy() {
  [ "${SATELLITE_EXECUTOR}" = "argo" ] || return 1
  [ "$(oc get applications.argoproj.io satellite-config -n openshift-gitops -o jsonpath='{.status.operationState.phase}' 2>/dev/null)" = "Running" ]
}

# wait_satellite_apply SINCE_UTC [timeout_s] -> 0 when a run started after
# SINCE succeeded, 1 when it failed, 2 on timeout. Prints where to look.
wait_satellite_apply() {
  local since="$1" timeout="${2:-600}" t=0 last created status
  while [ "${t}" -lt "${timeout}" ]; do
    last=$(satellite_apply_last)
    created="${last%% *}"; status=$(awk '{print $2}' <<<"${last}")
    if [ -n "${created}" ] && [[ ! "${created}" < "${since}" ]]; then
      case "${status}" in
        successful) return 0 ;;
        failed|error|canceled) return 1 ;;
      esac
    fi
    sleep 5; t=$((t + 5))
  done
  return 2
}

satellite_apply_where() {
  if [ "${SATELLITE_EXECUTOR}" = "aap" ]; then
    echo "AAP -> Jobs -> ${SAT_APPLY_TEMPLATE}"
  else
    echo "Argo CD satellite-config -> satellite-cac -> Logs (oc logs -n ${NAMESPACE} job/satellite-cac)"
  fi
}
