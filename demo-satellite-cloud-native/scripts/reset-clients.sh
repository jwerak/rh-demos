#!/bin/bash
set -euo pipefail

# Reset client VMs: deregister from Satellite + IdM, delete VMs and PVCs.
# Leaves Satellite, IdM, and infrastructure intact.
#
# Usage: ./scripts/reset-clients.sh

NAMESPACE="satellite-cloud-native"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${DEMO_PASSWORD:-}" ] && [ -f "${SCRIPT_DIR}/../.env" ]; then
  source "${SCRIPT_DIR}/../.env"
fi
: "${DEMO_PASSWORD:?DEMO_PASSWORD not set. Run: source .env}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

run_on_vm() {
  local vmi_name="$1"
  shift
  sshpass -p "${DEMO_PASSWORD}" ssh ${SSH_OPTS} \
    -o ProxyCommand="virtctl port-forward --stdio vmi/${vmi_name}.${NAMESPACE} 22" \
    cloud-user@localhost "$@"
}

echo "=== Resetting client VMs ==="
echo ""

# Scale pool to 0
echo "--- Step 1: Scaling client pool to 0 ---"
oc scale vmpool client-pool -n "${NAMESPACE}" --replicas=0 2>/dev/null || true
echo "Pool scaled to 0"

# Delete standalone client VMs (not pool-managed)
echo ""
echo "--- Step 2: Deleting client VMs ---"
for VM in $(oc get vm -n "${NAMESPACE}" -l role=client -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  # Skip pool-managed VMs (handled by scale-to-0)
  if oc get vm "${VM}" -n "${NAMESPACE}" -o jsonpath='{.metadata.labels.kubevirt\.io/vmpool}' 2>/dev/null | grep -q .; then
    echo "  ${VM} (pool-managed, skipping — handled by scale-to-0)"
    continue
  fi
  echo "  Deleting VM: ${VM}"
  oc delete vm "${VM}" -n "${NAMESPACE}" --wait=false 2>/dev/null || true
done

# Wait for VMIs to terminate
echo ""
echo "Waiting for client VMIs to terminate..."
for i in $(seq 1 30); do
  REMAINING=$(oc get vmi -n "${NAMESPACE}" -l role=client --no-headers 2>/dev/null | wc -l)
  [ "${REMAINING}" -eq 0 ] && break
  echo "  ${REMAINING} VMI(s) still terminating..."
  sleep 5
done
echo "All client VMIs terminated."

# Delete orphaned client PVCs (DataVolumes)
echo ""
echo "--- Step 3: Deleting client PVCs ---"
for PVC in $(oc get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '{print $1}' | grep -E '(client-rootdisk|pool-rootdisk|compliant-client-rootdisk)'); do
  echo "  Deleting PVC: ${PVC}"
  oc delete pvc "${PVC}" -n "${NAMESPACE}" 2>/dev/null || true
done

# Deregister from Satellite (all at once in a single SSH session)
echo ""
echo "--- Step 4: Deregistering clients from Satellite ---"
run_on_vm satellite "sudo bash -c '
  for HOST in \$(hammer --csv host list --search \"name ~ client\" --organization Demo_Org 2>/dev/null | tail -n +2 | cut -d, -f2); do
    echo \"  Removing from Satellite: \${HOST}\"
    hammer host delete --name \"\${HOST}\" --organization Demo_Org 2>/dev/null || true
  done
  echo \"  Remaining hosts:\"
  hammer host list --organization Demo_Org 2>/dev/null
'" 2>/dev/null || true

# Deregister from IdM (all at once in a single SSH session)
echo ""
echo "--- Step 5: Deregistering clients from IdM ---"
run_on_vm idm "sudo bash -c '
  echo \"${DEMO_PASSWORD}\" | kinit admin 2>/dev/null
  for HOST in \$(ipa host-find --sizelimit=100 2>/dev/null | grep -oP \"Host name: \K.*client.*\"); do
    echo \"  Removing from IdM: \${HOST}\"
    ipa host-del \"\${HOST}\" --updatedns 2>/dev/null || true
  done
  echo \"  Remaining hosts:\"
  ipa host-find 2>/dev/null | grep \"Host name:\" || true
'" 2>/dev/null || true

echo ""
echo "=== Client reset complete ==="
echo ""
echo "Satellite and IdM are untouched. To re-deploy clients:"
echo "  ./scripts/demo-scenarios.sh 1     # Single client"
echo "  ./scripts/demo-scenarios.sh 2     # Scale pool"
echo "  ./scripts/demo-scenarios.sh 12    # CIS-hardened client"
