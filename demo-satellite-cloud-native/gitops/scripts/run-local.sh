#!/bin/bash
# Fallback runner: apply the Satellite configuration from this laptop, from the
# same Git repository, when the in-cluster Job is unavailable.
#
# Usage: gitops/scripts/run-local.sh [ansible-playbook args, e.g. --tags releases --check]
#
# Source of truth stays Git: the playbook runs from a fresh checkout of main in
# Gitea (falls back to gitops/repo/ if Gitea is unreachable, and says so).
# Runs with ansible-navigator in the runner image (podman build if missing);
# Satellite is reached on https://SAT_FQDN, so the laptop needs that name to
# resolve (route CNAME). The registration Secret is applied with `oc`.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd ansible-navigator podman git

IMAGE=localhost/satellite-cac-runner:latest
if ! podman image exists "${IMAGE}"; then
  log "Building ${IMAGE}"
  podman build -t "${IMAGE}" "${GITOPS_DIR}/runner"
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

# The playbook falls back to `oc apply` for the registration Secret when it
# is not running in a pod; inside the EE that needs oc and a kubeconfig.
# Copies, not the originals: ":Z" would relabel the host files, and the EE
# user (UID 1001 under rootless podman) cannot read a 0600 kubeconfig.
cp "${KUBECONFIG:-${HOME}/.kube/config}" "${WORK}/kubeconfig"
cp "$(command -v oc)" "${WORK}/oc"
chmod 0644 "${WORK}/kubeconfig"; chmod 0755 "${WORK}/oc"

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
  --eev "${WORK}/kubeconfig:/runner/kubeconfig:Z" --eev "${WORK}/oc:/usr/local/bin/oc:Z" \
  --playbook-artifact-enable false \
  "$@"
