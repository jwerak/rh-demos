#!/bin/bash
set -euo pipefail

NAMESPACE="satellite-cloud-native"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${DEMO_PASSWORD:-}" ] && [ -f "${SCRIPT_DIR}/../.env" ]; then
  source "${SCRIPT_DIR}/../.env"
fi
: "${DEMO_PASSWORD:?DEMO_PASSWORD not set. Run: source .env}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Source the platform driver (provides run_on_vm, list_vms_by_role, get_service_url, etc.)
source "${SCRIPT_DIR}/platform-${DEMO_PLATFORM:-openshift}.sh"

echo "=== Registration Verification ==="
echo ""

# Check VM status
echo "--- VM Status ---"
if [ "${DEMO_PLATFORM:-openshift}" = "libvirt" ]; then
  _libvirt_ssh "virsh list --all" 2>/dev/null || echo "  Could not list VMs on libvirt host"
else
  oc get vm,vmi -n "${NAMESPACE}"
fi
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
if [ "${DEMO_PLATFORM:-openshift}" = "libvirt" ]; then
  for NAME in $(list_vms_by_role client-pool); do
    echo -n "  ${NAME}: "
    run_on_vm "${NAME}" "sudo subscription-manager identity" 2>/dev/null && \
      echo "registered" || echo "not registered"
  done
else
  for VMI in $(oc get vmi -n "${NAMESPACE}" -l kubevirt.io/vmpool=client-pool -o name 2>/dev/null); do
    NAME=$(echo "${VMI}" | cut -d/ -f2)
    echo -n "  ${NAME}: "
    run_on_vm "${NAME}" "sudo subscription-manager identity" 2>/dev/null && \
      echo "registered" || echo "not registered"
  done
fi
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

if [ "${DEMO_PLATFORM:-openshift}" = "libvirt" ]; then
  for NAME in $(list_vms_by_role client-pool); do
    echo "${NAME}:"
    run_on_vm "${NAME}" "echo '${DEMO_PASSWORD}' | kinit demouser 2>/dev/null && klist" 2>/dev/null || \
      echo "  Could not obtain Kerberos ticket on ${NAME}"
    echo ""
  done
else
  for VMI in $(oc get vmi -n "${NAMESPACE}" -l kubevirt.io/vmpool=client-pool -o name 2>/dev/null); do
    NAME=$(echo "${VMI}" | cut -d/ -f2)
    echo "${NAME}:"
    run_on_vm "${NAME}" "echo '${DEMO_PASSWORD}' | kinit demouser 2>/dev/null && klist" 2>/dev/null || \
      echo "  Could not obtain Kerberos ticket on ${NAME}"
    echo ""
  done
fi

# Satellite Web UI
echo "--- Satellite Web UI ---"
if [ "${DEMO_PLATFORM:-openshift}" = "libvirt" ]; then
  SAT_URL=$(get_service_url satellite 2>/dev/null || echo "https://${SAT_FQDN:-<unknown>}")
  echo "URL: ${SAT_URL}"
else
  ROUTE=$(oc get route satellite-ui -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "<pending>")
  echo "URL: https://${ROUTE}"
fi
echo "Credentials: admin / ${DEMO_PASSWORD}"
