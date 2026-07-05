#!/bin/bash

NAMESPACE="foreman-demo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../.env" 2>/dev/null || true

if [ -z "${FOREMAN_FQDN:-}" ]; then
  echo "ERROR: FOREMAN_FQDN not set. Run: source .env"
  exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
PASS="${DEMO_PASSWORD:-changeme}"
OK=0
FAIL=0

check() {
  local desc="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "  [PASS] ${desc}"
    OK=$((OK + 1))
  else
    echo "  [FAIL] ${desc}"
    FAIL=$((FAIL + 1))
  fi
}

ssh_foreman() {
  sshpass -p "${PASS}" ssh ${SSH_OPTS} \
    -o ProxyCommand="virtctl port-forward --stdio vmi/foreman.${NAMESPACE} 22" \
    cloud-user@localhost "$@"
}

echo "=== Foreman Demo Verification ==="
echo ""

# 1. Check VM status
echo "--- VMs ---"
check "Foreman VM exists" oc get vm foreman -n "${NAMESPACE}"
check "Foreman VMI is running" bash -c "oc get vmi foreman -n ${NAMESPACE} -o jsonpath='{.status.phase}' | grep -q Running"
echo ""

# 2. Check Kubernetes resources
echo "--- Kubernetes Resources ---"
check "Service exists" oc get svc foreman -n "${NAMESPACE}"
check "Route exists" oc get route foreman-ui -n "${NAMESPACE}"
check "Client pool exists" oc get vmpool client-pool -n "${NAMESPACE}"
echo ""

# 3. Check podman-compose inside the VM
echo "--- Podman-Compose Services ---"
check "SSH to Foreman VM" ssh_foreman "echo ok"
for SVC in app db orchestrator worker redis-cache redis-tasks; do
  check "Container: ${SVC}" ssh_foreman "sudo podman ps --format '{{.Names}}' | grep -q ${SVC}"
done
echo ""

# 4. Check Foreman API
echo "--- Foreman API ---"
check "API reachable (via route)" bash -c "curl -sk -u admin:${PASS} https://${FOREMAN_FQDN}/api/v2/status | grep -q '\"status\"'"
echo ""

# 5. Check registered hosts
echo "--- Registered Hosts ---"
HOSTS=$(curl -sk -u "admin:${PASS}" "https://${FOREMAN_FQDN}/api/v2/hosts" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('total', 0))" 2>/dev/null || echo "0")
echo "  Hosts registered in Foreman: ${HOSTS}"
echo ""

# Summary
echo "=== Results: ${OK} passed, ${FAIL} failed ==="
[ "${FAIL}" -eq 0 ] && exit 0 || exit 1
