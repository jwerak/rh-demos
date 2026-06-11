#!/bin/bash
set -euo pipefail

NAMESPACE="satellite-cloud-native"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${DEMO_PASSWORD:-}" ] && [ -f "${SCRIPT_DIR}/../.env" ]; then
  source "${SCRIPT_DIR}/../.env"
fi
SSH_PASS="${DEMO_PASSWORD:?DEMO_PASSWORD not set. Run: source .env}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Helper: run a command on a VM via virtctl port-forward + sshpass
run_on_vm() {
  local vmi_name="$1"
  shift
  sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} \
    -o ProxyCommand="virtctl port-forward --stdio vmi/${vmi_name}.${NAMESPACE} 22" \
    cloud-user@localhost "$@"
}

echo "=== Registration Verification ==="
echo ""

# Check VM status
echo "--- VM Status ---"
oc get vm,vmi -n "${NAMESPACE}"
echo ""

# Verify Satellite registration
echo "--- Satellite Registration ---"
echo "Checking client VM..."
run_on_vm client "sudo subscription-manager identity" 2>/dev/null && \
  echo "  -> Client is registered to Satellite" || \
  echo "  -> Client NOT registered to Satellite (still provisioning?)"
echo ""

# Check all pool clients
echo "Checking pool clients..."
for VMI in $(oc get vmi -n "${NAMESPACE}" -l kubevirt.io/vmpool=client-pool -o name 2>/dev/null); do
  NAME=$(echo "${VMI}" | cut -d/ -f2)
  echo -n "  ${NAME}: "
  run_on_vm "${NAME}" "sudo subscription-manager identity" 2>/dev/null && \
    echo "registered" || echo "not registered"
done
echo ""

# Verify IdM enrollment
echo "--- IdM Enrollment ---"
echo "Checking hosts enrolled in IdM..."
run_on_vm idm "echo '${DEMO_PASSWORD}' | kinit admin 2>/dev/null && ipa host-find --sizelimit=100" 2>/dev/null || \
  echo "  Could not query IdM (still installing?)"
echo ""

# Verify Kerberos tickets
echo "--- Kerberos Ticket Verification ---"
echo "Client VM:"
run_on_vm client "echo '${DEMO_PASSWORD}' | kinit demouser 2>/dev/null && klist" 2>/dev/null || \
  echo "  Could not obtain Kerberos ticket on client"
echo ""

for VMI in $(oc get vmi -n "${NAMESPACE}" -l kubevirt.io/vmpool=client-pool -o name 2>/dev/null); do
  NAME=$(echo "${VMI}" | cut -d/ -f2)
  echo "${NAME}:"
  run_on_vm "${NAME}" "echo '${DEMO_PASSWORD}' | kinit demouser 2>/dev/null && klist" 2>/dev/null || \
    echo "  Could not obtain Kerberos ticket on ${NAME}"
  echo ""
done

# Satellite Web UI
echo "--- Satellite Web UI ---"
ROUTE=$(oc get route satellite-ui -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "<pending>")
echo "URL: https://${ROUTE}"
echo "Credentials: admin / ${DEMO_PASSWORD}"
