#!/bin/bash
# Render gitops/README.md into one self-contained offline HTML run sheet with
# the real URLs and logins of this cluster filled in.
#
#   DEMO_ENV_FILE=.env.ocp gitops/scripts/render-runsheet.sh [OUTPUT]
#
# OUTPUT defaults to ~/.cache/satellite-demo/runsheet.html (mode 0600). The
# page contains credentials: never commit it. Inside a git work tree only
# *.local.html / runsheet*.html are accepted (both gitignored).
#
# Placeholders {{NAME}} in the Markdown are filled from RUNSHEET_<NAME>. Every
# lookup is best effort; a RUNSHEET_* variable already set in the environment
# wins over the lookup.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

OUTPUT="${1:-${CACHE_DIR}/runsheet.html}"
INPUT="${RUNSHEET_INPUT:-${GITOPS_DIR}/README.md}"

FOUND=()
MISSING=()

# setv NAME VALUE: export RUNSHEET_NAME unless already set; never prints values.
setv() {
  local name="$1" val="$2" var="RUNSHEET_$1"
  if [ -n "${!var:-}" ]; then
    FOUND+=("${name}(preset)")
  elif [ -n "${val}" ]; then
    export "${var}=${val}"
    FOUND+=("${name}")
  else
    MISSING+=("${name}")
  fi
}

route_url() {  # route_url NAME NAMESPACE -> https://host or nothing
  local h
  h=$(oc get route "$1" -n "$2" -o jsonpath='{.spec.host}' 2>/dev/null) || return 0
  [ -n "${h}" ] && echo "https://${h}"
}

# Next free demo-app major version, as N.0 (same rule as reset.sh).
next_version() {
  sat_hammer '--csv --no-headers package list --repository demo-app-rpms --product Demo-App --organization Demo_Org --fields Filename' 2>/dev/null \
    | python3 -I -c '
import re, sys
majors = [int(m.group(1)) for m in re.finditer(r"demo-app-(\d+)\.(\d+)", sys.stdin.read())]
if majors:
    print("%d.0" % (max(majors) + 1))
'
}

log "Collecting run sheet values (${DEMO_ENV_FILE})"
oc whoami >/dev/null 2>&1 || warn "not logged in to OpenShift: cluster URLs will be missing"

setv SAT_URL "https://${SAT_FQDN}"
setv IDM_URL "${IDM_FQDN:+https://${IDM_FQDN}}"
GITEA_URL_V=$(gitea_url 2>/dev/null || true)
setv GITEA_URL "${GITEA_URL_V}"
setv GITEA_REPO_URL "${GITEA_URL_V:+${GITEA_URL_V}/${GITEA_USER}/${GITEA_REPO}}"
setv GITEA_USER "${GITEA_USER}"
setv AAP_URL "$(aap_url 2>/dev/null || true)"
setv ARGOCD_URL "$(route_url openshift-gitops-server openshift-gitops)"
setv CONSOLE_URL "$(oc whoami --show-console 2>/dev/null || true)"
setv APPS_DOMAIN "$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
setv LC_DEV_URL "$(route_url lc-dev-web "${NAMESPACE}")"
setv LC_QA_URL "$(route_url lc-qa-web "${NAMESPACE}")"
setv LC_PROD_URL "$(route_url lc-prod-web "${NAMESPACE}")"
setv DEMO_PASSWORD "${DEMO_PASSWORD}"
setv AAP_PASSWORD "$(aap_password 2>/dev/null || true)"
# Example numbers in the run sheet: baseline version (reset.sh --save-baseline)
# and the composite version the next publish will create.
setv BASELINE "$(sed -nE 's/.*Dev=([0-9.]+).*/\1/p' "${CACHE_DIR}/gitops-baseline" 2>/dev/null || true)"
NEXT_CV=$(satellite_latest_version 2>/dev/null || true)
[[ "${NEXT_CV}" =~ ^[0-9]+ ]] && NEXT_CV="$(( ${NEXT_CV%%.*} + 1 )).0" || NEXT_CV=""
setv NEXT_CV_VERSION "${NEXT_CV}"

if [ -z "${RUNSHEET_NEXT_VERSION:-}" ]; then
  log "Asking Satellite for the next demo-app version (hammer, ~10 s)"
  setv NEXT_VERSION "$(next_version 2>/dev/null || true)"
else
  setv NEXT_VERSION ""
fi

echo "  found:   ${FOUND[*]:-none}"
echo "  missing: ${MISSING[*]:-none}"

python3 -I "${GITOPS_DIR}/scripts/render_runsheet.py" "${INPUT}" "${OUTPUT}" || die "rendering failed"

OUT_ABS="$(cd "$(dirname "${OUTPUT}")" && pwd)/$(basename "${OUTPUT}")"
log "Run sheet: ${OUT_ABS}"
echo "  file://${OUT_ABS}"
