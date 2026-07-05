#!/bin/bash
set -euo pipefail

NAMESPACE="foreman-demo"

if [ -z "${RHSM_ORG:-}" ] || [ -z "${RHSM_ACTIVATION_KEY:-}" ]; then
  echo "ERROR: RHSM_ORG and RHSM_ACTIVATION_KEY must be set."
  echo ""
  echo "  source .env"
  echo "  $0"
  exit 1
fi

oc new-project "${NAMESPACE}" 2>/dev/null || true

oc create secret generic rhsm-credentials \
  -n "${NAMESPACE}" \
  --from-literal=org="${RHSM_ORG}" \
  --from-literal=activationkey="${RHSM_ACTIVATION_KEY}"

echo "Secret 'rhsm-credentials' created in namespace '${NAMESPACE}'."
