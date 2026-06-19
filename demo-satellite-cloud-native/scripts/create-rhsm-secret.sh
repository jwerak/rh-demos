#!/bin/bash
set -euo pipefail

NAMESPACE="satellite-cloud-native"
oc new-project "${NAMESPACE}"

if [ -z "${RHSM_ORG:-}" ] || [ -z "${RHSM_ACTIVATION_KEY:-}" ]; then
  echo "Error: RHSM_ORG and RHSM_ACTIVATION_KEY must be set."
  echo ""
  echo "  cp .env.sample .env"
  echo "  # Edit .env with your values"
  echo "  source .env"
  echo "  $0"
  exit 1
fi

echo "Creating RHSM credentials secret in namespace ${NAMESPACE}..."
oc create secret generic rhsm-credentials \
  -n "${NAMESPACE}" \
  --from-literal=org="${RHSM_ORG}" \
  --from-literal=activationkey="${RHSM_ACTIVATION_KEY}" \
  --dry-run=client -o yaml | oc apply -f -

echo "Done. RHSM credentials stored in secret/rhsm-credentials"
