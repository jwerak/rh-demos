#!/bin/bash
set -euo pipefail

NAMESPACE="foreman-demo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="${SCRIPT_DIR}/../k8s/base"

echo "=== Foreman PF6 Demo Deployment ==="
echo ""

# --- Validate required environment variables ---
if [ -z "${FOREMAN_FQDN:-}" ]; then
  echo "ERROR: FOREMAN_FQDN must be set."
  echo ""
  echo "  cp .env.sample .env"
  echo "  # Edit .env with your values"
  echo "  source .env"
  echo "  $0"
  exit 1
fi

# --- Generate or load demo password ---
if [ -z "${DEMO_PASSWORD:-}" ]; then
  DEMO_PASSWORD=$(openssl rand -base64 12)
  echo "DEMO_PASSWORD='${DEMO_PASSWORD}'" >> "${SCRIPT_DIR}/../.env"
  echo "Generated DEMO_PASSWORD and saved to .env"
fi

# Derive domain from FQDN (e.g. foreman.example.com -> example.com)
FOREMAN_DOMAIN="${FOREMAN_FQDN#*.}"
FOREMAN_IMAGE="${FOREMAN_IMAGE:-quay.io/jwerak/foreman:latest}"

echo "Foreman FQDN:   ${FOREMAN_FQDN}"
echo "Foreman Domain: ${FOREMAN_DOMAIN}"
echo "Foreman Image:  ${FOREMAN_IMAGE}"
echo ""

# Validate DNS resolution
echo "--- Validating DNS ---"
if host "${FOREMAN_FQDN}" > /dev/null 2>&1; then
  RESOLVED=$(dig +short "${FOREMAN_FQDN}" | tail -1)
  echo "  ${FOREMAN_FQDN} -> ${RESOLVED}"
else
  APPS_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "apps.cluster.example.com")
  echo "  WARNING: ${FOREMAN_FQDN} does not resolve."
  echo "  Create a CNAME record:"
  echo "    ${FOREMAN_FQDN} CNAME ${APPS_DOMAIN}"
fi
echo ""

# Helper: substitute placeholders in a YAML file and apply
apply_templated() {
  local file="$1"
  sed \
    -e "s|__FOREMAN_FQDN__|${FOREMAN_FQDN}|g" \
    -e "s|__FOREMAN_DOMAIN__|${FOREMAN_DOMAIN}|g" \
    -e "s|__FOREMAN_IMAGE__|${FOREMAN_IMAGE}|g" \
    -e "s|__DEMO_PASSWORD__|${DEMO_PASSWORD}|g" \
    "$file" | oc apply -f -
}

# Phase 0: Create namespace and check prerequisites
echo "--- Phase 0: Creating namespace and checking prerequisites ---"
oc apply -f "${BASE_DIR}/namespace.yaml"

if ! oc get secret rhsm-credentials -n "${NAMESPACE}" &>/dev/null; then
  echo ""
  echo "ERROR: Secret 'rhsm-credentials' not found in namespace '${NAMESPACE}'."
  echo ""
  echo "Create it by running:"
  echo "  source .env"
  echo "  ./scripts/create-rhsm-secret.sh"
  exit 1
fi
echo "rhsm-credentials secret found."
echo ""

# Phase 1: Deploy Foreman server
echo "--- Phase 1: Deploying Foreman Server ---"
apply_templated "${BASE_DIR}/foreman-cloudinit-secret.yaml"
apply_templated "${BASE_DIR}/foreman-vm.yaml"
oc apply -f "${BASE_DIR}/foreman-service.yaml"
apply_templated "${BASE_DIR}/foreman-route.yaml"

echo "Waiting for Foreman VM to start..."
oc wait vm/foreman -n "${NAMESPACE}" --for=condition=Ready --timeout=300s 2>/dev/null || true
echo "Foreman VM is booting. Setup takes ~10-15 minutes (image pull + migrations)."
echo ""

# Phase 2: Deploy client cloud-init and pool (pool starts at 0 replicas)
echo "--- Phase 2: Deploying Client Configuration ---"
apply_templated "${BASE_DIR}/client-cloudinit-secret.yaml"
apply_templated "${BASE_DIR}/client-pool.yaml"
echo "Client pool deployed with 0 replicas (scale when Foreman is ready)."
echo ""

echo "=== Deployment Complete ==="
echo ""
echo "Next steps:"
echo "  1. Monitor Foreman install (~10-15 min):"
echo "     sshpass -p '${DEMO_PASSWORD}' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \\"
echo "       -o ProxyCommand=\"virtctl port-forward --stdio vmi/foreman.${NAMESPACE} 22\" \\"
echo "       cloud-user@localhost 'sudo tail -f /var/log/foreman-setup.log'"
echo ""
echo "  2. Deploy a single client (once Foreman is ready):"
echo "     oc apply -f <(sed \\"
echo "       -e 's|__FOREMAN_FQDN__|${FOREMAN_FQDN}|g' \\"
echo "       -e 's|__FOREMAN_DOMAIN__|${FOREMAN_DOMAIN}|g' \\"
echo "       -e 's|__DEMO_PASSWORD__|${DEMO_PASSWORD}|g' \\"
echo "       ${BASE_DIR}/client-vm.yaml)"
echo ""
echo "  3. Scale client pool:"
echo "     oc scale vmpool client-pool -n ${NAMESPACE} --replicas=2"
echo ""
echo "  4. Access Web UI:"
echo "     Foreman: https://${FOREMAN_FQDN}  (admin / ${DEMO_PASSWORD})"
