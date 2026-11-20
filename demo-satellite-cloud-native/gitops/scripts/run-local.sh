#!/bin/bash
# Fallback runner: apply the Satellite configuration from this laptop, from the
# same Git repository, when the in-cluster Job is unavailable.
#
# Usage: gitops/scripts/run-local.sh [ansible-playbook args, e.g. --tags releases --check]
#
# Source of truth stays Git: the playbook runs from a fresh checkout of main in
# Gitea (falls back to gitops/repo/ if Gitea is unreachable, and says so).
# Runs with ansible-navigator in AAP's supported EE (redhat.satellite);
# Satellite is reached on https://SAT_FQDN, so the laptop needs that name to
# resolve (route CNAME). Cluster writes use the laptop's kubeconfig.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd ansible-navigator podman git

# site.yml needs only what AAP's supported EE ships (redhat.satellite,
# kubernetes.core), so use it directly. Needs `podman login registry.redhat.io`.
IMAGE="${RUN_LOCAL_EE:-registry.redhat.io/ansible-automation-platform-27/ee-supported-rhel9:latest}"
if ! podman image exists "${IMAGE}"; then
  log "Pulling ${IMAGE}"
  podman pull -q "${IMAGE}" >/dev/null \
    || die "cannot pull ${IMAGE}: run 'podman login registry.redhat.io' (Customer Portal or service account) once"
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
export GIT_SSL_NO_VERIFY=true
if git clone -q --depth 1 "https://${GITEA_USER}:$(gitea_token 2>/dev/null)@$(gitea_host)/${GITEA_USER}/${GITEA_REPO}.git" "${WORK}/repo" 2>/dev/null; then
  log "Using Gitea main @ $(git -C "${WORK}/repo" rev-parse --short HEAD)"
else
  warn "Gitea unreachable: using local gitops/repo (NOT the reviewed state in Git)"
  cp -a "${GITOPS_DIR}/repo" "${WORK}/repo"
fi

# kubernetes.core writes the registration Secret and the drift ConfigMap with
# the laptop's kubeconfig. A copy, not the original: ":Z" would relabel the
# host file, and the EE user cannot read a 0600 kubeconfig.
cp "${KUBECONFIG:-${HOME}/.kube/config}" "${WORK}/kubeconfig"
chmod 0644 "${WORK}/kubeconfig"

cd "${WORK}/repo/satellite"
FOREMAN_SERVER_URL="https://${SAT_FQDN}" \
FOREMAN_USERNAME=admin \
FOREMAN_PASSWORD="${DEMO_PASSWORD}" \
FOREMAN_VALIDATE_CERTS=false \
POD_NAMESPACE="${NAMESPACE}" \
ansible-navigator run site.yml --mode stdout \
  --execution-environment-image "${IMAGE}" --pull-policy never \
  --penv FOREMAN_SERVER_URL --penv FOREMAN_USERNAME --penv FOREMAN_PASSWORD \
  --penv FOREMAN_VALIDATE_CERTS --penv POD_NAMESPACE \
  --senv KUBECONFIG=/runner/kubeconfig \
  --eev "${WORK}/kubeconfig:/runner/kubeconfig:Z" \
  --playbook-artifact-enable false \
  "$@"
