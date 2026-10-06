#!/usr/bin/env bash
# Tear the AO CVE lab down and build it back up.
#
#   cd demo-aiops/aiops-orchestrator/local
#   ./reprovision.sh                 # reset, then rebuild everything
#   ./reprovision.sh --reset-only    # tear down and stop
#   ./reprovision.sh --no-reset      # rebuild over what is already there
#   ./reprovision.sh --keep-vms      # leave the AWS instances and their
#                                    # Insights systems alone; clears the AO
#                                    # runs, Gitea, and generated templates
#
# Reads demo-aiops/aiops-orchestrator/.env. Nothing is echoed from it.
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f ../.env ]]; then
  echo "../.env is missing. Copy .env.sample and fill it in." >&2
  exit 1
fi

# Sourcing .env would otherwise overwrite a variable the caller set on the
# command line, so `AO_DEMO_CVE=CVE-... ./reprovision.sh` would silently do
# nothing. Keep the caller's value for the knobs meant to be overridden.
_overrides=()
for _v in AO_DEMO_CVE AO_DEMO_HOST AO_NODE_SUFFIX AO_INSIGHTS_GROUP; do
  if [[ -n "${!_v:-}" ]]; then
    _overrides+=("$_v=${!_v}")
  fi
done

set -a
# shellcheck disable=SC1091
source ../.env
set +a

for _o in ${_overrides[@]+"${_overrides[@]}"}; do
  export "${_o?}"
  echo "override: ${_o%%=*}"
done

do_reset=true
do_build=true
reset_vms=true

for arg in "$@"; do
  case "$arg" in
    --reset-only) do_build=false ;;
    --no-reset) do_reset=false ;;
    --keep-vms) reset_vms=false ;;
    -h | --help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

# AO_DEMO_CVE has to be a CVE Lightspeed lists for the host with an errata.
# The triage prompt does not pick one when the trigger field is empty.
if [[ -z "${AO_DEMO_CVE:-}" ]]; then
  echo "note: AO_DEMO_CVE is unset, so the workflow trigger will have no default CVE."
fi

run() {
  echo
  echo "=== $1"
  shift
  "$@"
}

if [[ "$do_reset" == true ]]; then
  run "reset the lab" ansible-navigator run ../playbooks/reset-lab.yml \
    --penv CONTROLLER_HOST --penv CONTROLLER_USERNAME --penv CONTROLLER_PASSWORD \
    --penv AO_URL --penv AO_USERNAME --penv AO_PASSWORD \
    --penv GITEA_URL --penv GITEA_TOKEN --penv GITEA_REPO \
    --penv LIGHTSPEED_CLIENT_ID --penv LIGHTSPEED_CLIENT_SECRET \
    --penv AO_NODE_SUFFIX \
    -e "ao_reset_vms=${reset_vms}" -e "ao_reset_insights=${reset_vms}"
fi

if [[ "$do_build" == false ]]; then
  echo
  echo "Reset done. Skipping the rebuild."
  exit 0
fi

# Create VM skips an instance that already carries the Name tag, so there is
# only a point launching the provisioning workflow when the reset just removed
# them. Rebuilding over a live lab skips straight to the AO side.
launch_workflow=false
if [[ "$do_reset" == true && "$reset_vms" == true ]]; then
  launch_workflow=true
fi

run "AAP objects and nodes" ansible-navigator run ../playbooks/configure-aap.yml \
  --penv CONTROLLER_HOST --penv CONTROLLER_USERNAME --penv CONTROLLER_PASSWORD \
  --penv RHSM_ORG_ID --penv RHSM_ACTIVATION_KEY \
  --penv GITEA_URL --penv GITEA_TOKEN --penv GITEA_REPO \
  --penv AO_INSIGHTS_GROUP --penv AO_NODE_SUFFIX --penv LIGHTSPEED_MCP_SERVICE \
  -e "ao_launch_workflow=${launch_workflow}"

# Keeping the instances across a stop/start of the lab environment leaves
# lab-inventory holding their old public IPs, and every job then fails to
# connect. Re-sync the AWS inventory and rewrite ansible_host. The
# provisioning workflow already ends in a wire, so only do this when it
# did not run.
if [[ "$launch_workflow" == false ]]; then
  run "refresh the node addresses" ansible-navigator run ../playbooks/wire-lab-inventory.yml \
    --penv CONTROLLER_HOST --penv CONTROLLER_USERNAME --penv CONTROLLER_PASSWORD \
    --penv AO_NODE_SUFFIX
fi

run "AO credentials and integrations" ansible-navigator run ../playbooks/configure-ao.yml \
  --penv AO_URL --penv AO_USERNAME --penv AO_PASSWORD \
  --penv AO_MODEL_BASE_URL --penv AO_MODEL_NAME --penv AO_MODEL_ACCESS_TOKEN \
  --penv CONTROLLER_HOST --penv CONTROLLER_USERNAME --penv CONTROLLER_PASSWORD \
  --penv AAP_MCP_TOKEN --penv AAP_MCP_URL --penv LIGHTSPEED_MCP_URL

run "AO workflow" ansible-navigator run ../playbooks/configure-ao-workflow.yml \
  --penv AO_URL --penv AO_USERNAME --penv AO_PASSWORD --penv AO_MODEL_NAME \
  --penv CONTROLLER_HOST --penv AO_INSIGHTS_GROUP \
  --penv AO_DEMO_CVE --penv AO_DEMO_HOST --penv AO_NODE_SUFFIX

echo
echo "Lab rebuilt."
echo "Insights needs a few minutes after registration before the CVE counts appear."
