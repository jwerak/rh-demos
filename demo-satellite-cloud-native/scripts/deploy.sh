#!/bin/bash
set -euo pipefail

NAMESPACE="satellite-cloud-native"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="${SCRIPT_DIR}/../k8s/base"

echo "=== Cloud-Native Satellite + IdM Demo Deployment ==="
echo ""

# --- Validate required environment variables ---
if [ -z "${IDM_FQDN:-}" ] || [ -z "${SAT_FQDN:-}" ]; then
  echo "ERROR: IDM_FQDN and SAT_FQDN must be set."
  echo ""
  echo "These are the DNS names for the IdM and Satellite Web UIs."
  echo "They must have CNAME records pointing to the OpenShift router."
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

# Derive IPA domain and realm from the IdM FQDN
# e.g. idm.veverak.net → domain=veverak.net, realm=VEVERAK.NET
IPA_DOMAIN="${IDM_FQDN#*.}"
IPA_REALM=$(echo "${IPA_DOMAIN}" | tr '[:lower:]' '[:upper:]')

echo "IdM FQDN:          ${IDM_FQDN}"
echo "Satellite FQDN:    ${SAT_FQDN}"
echo "IPA domain/realm:  ${IPA_DOMAIN} / ${IPA_REALM}"
echo ""

# Validate DNS resolution
echo "--- Validating DNS ---"
for FQDN in "${IDM_FQDN}" "${SAT_FQDN}"; do
  if host "${FQDN}" > /dev/null 2>&1; then
    RESOLVED=$(dig +short "${FQDN}" | tail -1)
    echo "  ${FQDN} -> ${RESOLVED}"
  else
    echo "  WARNING: ${FQDN} does not resolve. Create a CNAME record first."
    echo "    ${FQDN} CNAME $(echo "${FQDN}" | sed "s|${IPA_DOMAIN}|$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')|")"
  fi
done
echo ""

# Helper: substitute placeholders in a YAML file and apply
apply_templated() {
  local file="$1"
  sed \
    -e "s|__IDM_FQDN__|${IDM_FQDN}|g" \
    -e "s|__SAT_FQDN__|${SAT_FQDN}|g" \
    -e "s|__IPA_DOMAIN__|${IPA_DOMAIN}|g" \
    -e "s|__IPA_REALM__|${IPA_REALM}|g" \
    -e "s|__DEMO_PASSWORD__|${DEMO_PASSWORD}|g" \
    "$file" | oc apply -f -
}

# Phase 0: Create namespace and check prerequisites
echo "--- Phase 0: Creating namespace and checking prerequisites ---"
oc apply -f "${BASE_DIR}/namespace.yaml"

if ! oc get secret rhsm-credentials -n "${NAMESPACE}" &>/dev/null; then
  echo ""
  echo "ERROR: Secret 'rhsm-credentials' not found in namespace '${NAMESPACE}'."
  echo "All VMs require this secret for RHSM registration."
  echo ""
  echo "Create it by running:"
  echo "  source .env"
  echo "  ./scripts/create-rhsm-secret.sh"
  echo ""
  exit 1
fi
echo "rhsm-credentials secret found."
echo ""

# Phase 1: Deploy IdM first (other services depend on it)
echo "--- Phase 1: Deploying IdM Server ---"
apply_templated "${BASE_DIR}/idm-cloudinit-secret.yaml"
apply_templated "${BASE_DIR}/idm-vm.yaml"
oc apply -f "${BASE_DIR}/idm-service.yaml"
apply_templated "${BASE_DIR}/idm-route.yaml"

echo "Waiting for IdM VM to start..."
oc wait vm/idm -n "${NAMESPACE}" --for=condition=Ready --timeout=300s 2>/dev/null || true
echo "IdM VM is booting. Installation takes ~10 minutes."
echo ""

# Phase 2: Deploy Satellite (can run in parallel with IdM install)
echo "--- Phase 2: Deploying Satellite Server ---"
oc apply -f "${BASE_DIR}/satellite-data-pvc.yaml"
apply_templated "${BASE_DIR}/satellite-cloudinit-secret.yaml"
apply_templated "${BASE_DIR}/satellite-vm.yaml"
oc apply -f "${BASE_DIR}/satellite-service.yaml"
apply_templated "${BASE_DIR}/satellite-route.yaml"

echo "Waiting for Satellite VM to start..."
oc wait vm/satellite -n "${NAMESPACE}" --for=condition=Ready --timeout=300s 2>/dev/null || true
echo "Satellite VM is booting. Installation takes ~20-30 minutes."
echo ""

# Phase 3: Deploy network policy
echo "--- Phase 3: Applying Network Policies ---"
oc apply -f "${BASE_DIR}/network-policy.yaml"
echo ""

# Phase 4: Deploy client cloud-init and pool (pool starts at 0 replicas)
echo "--- Phase 4: Deploying Client Configuration ---"
apply_templated "${BASE_DIR}/client-cloudinit-secret.yaml"
apply_templated "${BASE_DIR}/client-pool.yaml"
echo "Client pool deployed with 0 replicas (scale when infra is ready)."
echo ""

# Phase 5: Upload subscription manifest (optional, requires MANIFEST_PATH)
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
MANIFEST_UPLOADED=false
if [ -n "${MANIFEST_PATH:-}" ]; then
  echo "--- Phase 5: Uploading Subscription Manifest ---"
  echo "MANIFEST_PATH is set. Will upload after Satellite installation completes."
  echo "This typically takes 20-30 minutes."
  echo ""

  echo "Waiting for Satellite installation to complete..."
  while true; do
    if sshpass -p "${DEMO_PASSWORD}" ssh ${SSH_OPTS} \
         -o ProxyCommand="virtctl port-forward --stdio vmi/satellite.${NAMESPACE} 22" \
         cloud-user@localhost \
         "sudo grep -q 'Satellite Configuration Complete' /var/log/satellite-setup.log" 2>/dev/null; then
      echo "Satellite installation complete!"
      break
    fi
    echo "  Still installing... ($(date +%H:%M:%S), checking every 60s)"
    sleep 60
  done
  echo ""

  echo "Waiting for background tasks to finish before manifest upload..."
  for i in $(seq 1 30); do
    if ! sshpass -p "${DEMO_PASSWORD}" ssh ${SSH_OPTS} \
         -o ProxyCommand="virtctl port-forward --stdio vmi/satellite.${NAMESPACE} 22" \
         cloud-user@localhost \
         "sudo hammer task list --search 'state = running' --per-page 100 2>/dev/null | grep -q running" 2>/dev/null; then
      break
    fi
    echo "  Tasks still running... ($(date +%H:%M:%S), checking every 30s)"
    sleep 30
  done
  echo ""

  echo "Uploading manifest..."
  "${SCRIPT_DIR}/upload-manifest.sh" && MANIFEST_UPLOADED=true
  echo ""
fi

echo "=== Deployment Complete ==="
echo ""
echo "Next steps:"
echo "  1. Monitor IdM install (~10 min):"
echo "     sshpass -p '${DEMO_PASSWORD}' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \\"
echo "       -o ProxyCommand=\"virtctl port-forward --stdio vmi/idm.${NAMESPACE} 22\" \\"
echo "       cloud-user@localhost 'tail -f /var/log/idm-setup.log'"
echo ""
echo "  2. Monitor Satellite install (~20-30 min):"
echo "     sshpass -p '${DEMO_PASSWORD}' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \\"
echo "       -o ProxyCommand=\"virtctl port-forward --stdio vmi/satellite.${NAMESPACE} 22\" \\"
echo "       cloud-user@localhost 'tail -f /var/log/satellite-setup.log'"
echo ""
if [ "${MANIFEST_UPLOADED}" = true ]; then
echo "  3. Manifest uploaded successfully."
else
echo "  3. Upload subscription manifest (once Satellite is installed):"
echo "     export MANIFEST_PATH=/path/to/manifest.zip"
echo "     ./scripts/upload-manifest.sh"
fi
echo ""
echo "  4. Scale client pool (once infra is ready):"
echo "     oc scale vmpool client-pool -n ${NAMESPACE} --replicas=2"
echo ""
echo "  5. Access Web UIs:"
echo "     Satellite: https://${SAT_FQDN}  (admin / ${DEMO_PASSWORD})"
echo "     IdM:       https://${IDM_FQDN}  (admin / ${DEMO_PASSWORD})"
