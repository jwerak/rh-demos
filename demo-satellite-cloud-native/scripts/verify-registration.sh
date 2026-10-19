#!/bin/bash
set -euo pipefail

NAMESPACE="satellite-cloud-native"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_ENV_PATH="${DEMO_ENV_FILE:-${SCRIPT_DIR}/../.env}"
case "${DEMO_ENV_PATH}" in
  /*) : ;;
  *) DEMO_ENV_PATH="${SCRIPT_DIR}/../${DEMO_ENV_PATH}" ;;
esac
if [ -z "${DEMO_PASSWORD:-}" ] && [ -f "${DEMO_ENV_PATH}" ]; then
  # shellcheck disable=SC1090
  source "${DEMO_ENV_PATH}"
fi
: "${DEMO_PASSWORD:?DEMO_PASSWORD not set. Run: source .env}"
: "${DEPLOY_IDM:=true}"
: "${DEPLOY_CAPSULE:=false}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Source the platform driver (provides run_on_vm, list_vms_by_role, get_service_url, etc.)
source "${SCRIPT_DIR}/platform-${DEMO_PLATFORM:-openshift}.sh"

echo "=== Registration Verification ==="
echo ""

# Check VM status
echo "--- VM Status ---"
if [ "${DEMO_PLATFORM:-openshift}" = "libvirt" ]; then
  _virsh "list --all" 2>/dev/null || echo "  Could not list VMs on libvirt host"
else
  oc get vm,vmi -n "${NAMESPACE}"
fi
echo ""

# Verify Satellite registration
echo "--- Satellite Registration ---"
# The sections A/B RHEL client is not deployed by every profile, so only
# report on it when it actually exists.
if [ "${DEMO_PLATFORM:-openshift}" != "libvirt" ] || vm_exists client; then
  echo "Checking client VM..."
  run_on_vm client "sudo subscription-manager identity" 2>/dev/null && \
    echo "  -> Client is registered to Satellite" || \
    echo "  -> Client NOT registered to Satellite (still provisioning?)"
else
  echo "Client VM not deployed in this profile, skipping."
fi
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

# Verify Capsule (libvirt local profile only)
if [ "${DEPLOY_CAPSULE}" = "true" ]; then
  echo "--- Capsule ---"
  echo "Capsules known to the Satellite:"
  run_on_vm satellite "sudo hammer capsule list" 2>/dev/null || \
    echo "  Could not query the Satellite for Capsules"
  echo ""
  echo "Capsule content:"
  run_on_vm satellite "sudo hammer capsule content info --name '${CAPSULE_FQDN:-capsule.demo.lab}' --organization Demo_Org" 2>/dev/null || \
    echo "  Could not query Capsule content (not joined yet?)"
  echo ""
  echo "Capsule services:"
  run_on_vm capsule "systemctl is-active pulpcore-api pulpcore-content foreman-proxy httpd" 2>/dev/null || \
    echo "  Could not reach the Capsule VM"
  echo ""
  echo "CentOS client:"
  run_on_vm centos "sudo subscription-manager identity" 2>/dev/null && \
    echo "  -> CentOS client is registered" || \
    echo "  -> CentOS client NOT registered (deploy it with: ./scripts/demo-scenarios.sh d2)"
  run_on_vm centos "grep -m1 baseurl /etc/yum.repos.d/redhat.repo" 2>/dev/null || true
  echo ""
fi

# Verify IdM enrollment
if [ "${DEPLOY_IDM}" = "true" ]; then
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
