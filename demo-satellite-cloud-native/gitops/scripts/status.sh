#!/bin/bash
# One screen of truth for the GitOps act: what Git declares, what Satellite
# serves, what the hosts have installed, and what Argo CD thinks.
#
# Usage: gitops/scripts/status.sh [--hosts]   (--hosts also asks every VM for rpm -q demo-app)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

echo "== Satellite as code: executor ${SATELLITE_EXECUTOR}, last apply run: $(satellite_apply_last || echo '?')"
echo
echo "== Argo CD"
oc get applications.argoproj.io -n openshift-gitops rhel-fleet $([ "${SATELLITE_EXECUTOR}" = argo ] && echo satellite-config) \
  -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' \
  2>/dev/null || echo "  (applications not found)"

echo
echo "== Git: satellite/releases.yml on main"
if [ -s "${GITEA_TOKEN_FILE}" ]; then
  gitea_api GET "/repos/${GITEA_USER}/${GITEA_REPO}/raw/satellite/releases.yml?ref=main" 2>/dev/null \
    | sed -nE 's/^  (Dev|QA|Prod): (.*)/  \1 \2/p' || echo "  (cannot read)"
else
  echo "  (no Gitea token)"
fi

echo
echo "== Satellite: RHEL9-FullStack versions"
sat_hammer 'content-view version list --content-view RHEL9-FullStack --organization Demo_Org --fields "Version,Lifecycle Environments"' 2>/dev/null \
  || echo "  (hammer failed)"

GIT_REL=$(gitea_api GET "/repos/${GITEA_USER}/${GITEA_REPO}/raw/satellite/releases.yml?ref=main" 2>/dev/null \
  | sed -nE 's/^  (Dev|QA|Prod): "?([0-9.]+)"?.*/\1=\2/p' | paste -sd' ' || true)
SAT_REL=$(satellite_releases 2>/dev/null || true)
if [ -n "${GIT_REL}" ] && [ "${GIT_REL}" = "${SAT_REL}" ]; then
  echo "  => Git and Satellite agree: ${SAT_REL}"
else
  echo "  => DRIFT: Git ${GIT_REL:-?} | Satellite ${SAT_REL:-?}  (record: release.sh record)"
fi

echo
echo "== Fleet VMs (role=fleet)"
oc get vm -n "${NAMESPACE}" -l role=fleet \
  -o custom-columns='NAME:.metadata.name,ENV:.metadata.labels.fleet\.demo/environment,BY:.metadata.labels.fleet\.demo/provisioned-by,STATUS:.status.printableStatus' \
  2>/dev/null

if [ "${1:-}" = "--hosts" ]; then
  echo
  echo "== demo-app installed"
  for vm in $(oc get vmi -n "${NAMESPACE}" -l 'role in (fleet,client)' -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    printf '  %-20s %s\n' "${vm}" \
      "$(run_on_vm "${vm}" 'rpm -q demo-app 2>/dev/null || echo -' 2>/dev/null | tail -1)"
  done
fi
