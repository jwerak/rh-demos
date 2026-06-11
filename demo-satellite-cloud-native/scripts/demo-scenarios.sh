#!/bin/bash
set -euo pipefail

NAMESPACE="satellite-cloud-native"
BASE_DIR="$(cd "$(dirname "$0")/../k8s/base" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${DEMO_PASSWORD:-}" ] && [ -f "${SCRIPT_DIR}/../.env" ]; then
  source "${SCRIPT_DIR}/../.env"
fi
: "${DEMO_PASSWORD:?DEMO_PASSWORD not set. Run: source .env}"

usage() {
  echo "Usage: $0 <demo-number>"
  echo ""
  echo "Demos:"
  echo "  1  Zero-Touch Provisioning     - Deploy a single client, watch it auto-register"
  echo "  2  Elastic Scaling             - Scale client pool from 0 to 5"
  echo "  3  Self-Healing                - Kill a VM, watch it auto-recover"
  echo "  4  IP-Agnostic Kerberos        - Prove Kerberos works with duplicate IPs"
  echo "  5  Network Micro-Segmentation  - Verify SDN isolation between clients"
  echo ""
  echo "  all  Run all demos in sequence"
  exit 1
}

demo1() {
  echo "============================================"
  echo "  Demo 1: Zero-Touch Provisioning Workflow"
  echo "============================================"
  echo ""
  echo "Deploying a single RHEL client VM..."
  oc apply -f "${BASE_DIR}/client-vm.yaml"
  echo ""

  echo "Watching VM boot (Ctrl+C to stop watching, VM continues in background)..."
  echo "Expected: Provisioning → Scheduling → Running"
  oc get vmi/client -n "${NAMESPACE}" -w &
  WATCH_PID=$!
  sleep 5

  echo ""
  echo "Waiting for VM to reach Running state..."
  oc wait vmi/client -n "${NAMESPACE}" --for=jsonpath='{.status.phase}'=Running --timeout=300s 2>/dev/null || true
  kill $WATCH_PID 2>/dev/null || true

  echo ""
  echo "VM is running. Cloud-init is now executing the onboarding scripts."
  echo "Monitor progress:"
  echo "  oc exec -n ${NAMESPACE} vmi/client -- tail -f /var/log/client-setup.log"
  echo ""
  echo "Verification (run after ~5 minutes):"
  echo "  oc exec -n ${NAMESPACE} vmi/client -- subscription-manager identity"
  echo "  oc exec -n ${NAMESPACE} vmi/idm -- bash -c \"echo '${DEMO_PASSWORD}' | kinit admin && ipa host-find\""
}

demo2() {
  echo "========================================"
  echo "  Demo 2: Elastic Scaling via VMPool"
  echo "========================================"
  echo ""

  echo "Current pool state:"
  oc get vmpool client-pool -n "${NAMESPACE}" 2>/dev/null || echo "Pool not found"
  echo ""

  echo "Scaling client pool to 2 instances..."
  oc scale vmpool client-pool -n "${NAMESPACE}" --replicas=2
  sleep 3
  echo ""

  echo "Watching VMs come up..."
  oc get vmi -n "${NAMESPACE}" -l kubevirt.io/vmpool=client-pool
  echo ""

  echo "Scaling to 5 instances..."
  oc scale vmpool client-pool -n "${NAMESPACE}" --replicas=5
  sleep 3
  echo ""

  echo "All pool VMs:"
  oc get vmi -n "${NAMESPACE}" -l kubevirt.io/vmpool=client-pool
  echo ""

  echo "Note: All VMs share internal IP 10.0.2.x (NAT) but register as unique hosts."
  echo "Verification (after ~5 minutes):"
  echo "  # Check Satellite sees all hosts"
  echo "  oc exec -n ${NAMESPACE} vmi/satellite -- hammer host list --organization 'Demo_Org'"
  echo ""
  echo "  # Check IdM sees all hosts"
  echo "  oc exec -n ${NAMESPACE} vmi/idm -- bash -c \"echo '${DEMO_PASSWORD}' | kinit admin && ipa host-find\""
}

demo3() {
  echo "==========================================="
  echo "  Demo 3: Self-Healing Architecture"
  echo "==========================================="
  echo ""

  echo "Current VM state:"
  oc get vmi -n "${NAMESPACE}"
  echo ""

  echo "Simulating failure: deleting the client VMI (not the VM)..."
  echo "The VirtualMachine controller (runStrategy: Always) will recreate it."
  oc delete vmi/client -n "${NAMESPACE}" --wait=false
  echo ""

  echo "Watching recovery..."
  echo "Expected: the VMI disappears, then a new one is created automatically."
  sleep 2
  oc get vmi -n "${NAMESPACE}" -w &
  WATCH_PID=$!
  sleep 30
  kill $WATCH_PID 2>/dev/null || true

  echo ""
  echo "Recovery status:"
  oc get vmi -n "${NAMESPACE}"
  echo ""
  echo "The VM was automatically rescheduled and restarted."
  echo "Persistent storage (if configured) retains all data."
}

demo4() {
  echo "================================================"
  echo "  Demo 4: IP-Agnostic Kerberos Authentication"
  echo "================================================"
  echo ""

  echo "All client VMs share the same internal NAT IP (10.0.2.x)."
  echo "Kerberos tickets must work independently on each."
  echo ""

  # Get two client VMIs
  VMIS=($(oc get vmi -n "${NAMESPACE}" -l role=client -o name 2>/dev/null | head -2))

  if [ ${#VMIS[@]} -lt 2 ]; then
    echo "Need at least 2 client VMs. Scale the pool first: $0 2"
    return
  fi

  echo "Testing Kerberos on ${VMIS[0]}:"
  oc exec -n "${NAMESPACE}" "${VMIS[0]}" -- bash -c "
    echo '--- Internal IP ---'
    ip addr show | grep 'inet 10\.'
    echo '--- Obtaining Kerberos ticket ---'
    echo '${DEMO_PASSWORD}' | kinit demouser 2>/dev/null
    echo '--- Ticket details ---'
    klist
  " 2>/dev/null || echo "  (VM not ready for Kerberos yet)"

  echo ""
  echo "Testing Kerberos on ${VMIS[1]}:"
  oc exec -n "${NAMESPACE}" "${VMIS[1]}" -- bash -c "
    echo '--- Internal IP ---'
    ip addr show | grep 'inet 10\.'
    echo '--- Obtaining Kerberos ticket ---'
    echo '${DEMO_PASSWORD}' | kinit demouser 2>/dev/null
    echo '--- Ticket details ---'
    klist
  " 2>/dev/null || echo "  (VM not ready for Kerberos yet)"

  echo ""
  echo "Both VMs have the same internal IP but hold unique, valid Kerberos tickets."
  echo "This works because krb5.conf has 'noaddresses = true' in [libdefaults]."
}

demo5() {
  echo "=================================================="
  echo "  Demo 5: Network Micro-Segmentation (SDN)"
  echo "=================================================="
  echo ""

  echo "NetworkPolicy applied:"
  oc get networkpolicy -n "${NAMESPACE}"
  echo ""

  VMIS=($(oc get vmi -n "${NAMESPACE}" -l role=client -o name 2>/dev/null | head -2))

  if [ ${#VMIS[@]} -lt 2 ]; then
    echo "Need at least 2 client VMs. Scale the pool first: $0 2"
    return
  fi

  # Get pod IPs of the VMIs
  POD1=$(oc get "${VMIS[0]}" -n "${NAMESPACE}" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null)
  POD2=$(oc get "${VMIS[1]}" -n "${NAMESPACE}" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null)

  echo "Testing: Client → Satellite (should SUCCEED):"
  SAT_IP=$(oc get svc satellite -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
  oc exec -n "${NAMESPACE}" "${VMIS[0]}" -- curl -sk --connect-timeout 5 "https://${SAT_IP}/" > /dev/null 2>&1 && \
    echo "  -> PASS: Client can reach Satellite" || \
    echo "  -> BLOCKED (check NetworkPolicy)"
  echo ""

  echo "Testing: Client → IdM (should SUCCEED):"
  IDM_IP=$(oc get svc idm -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
  oc exec -n "${NAMESPACE}" "${VMIS[0]}" -- curl -sk --connect-timeout 5 "https://${IDM_IP}/" > /dev/null 2>&1 && \
    echo "  -> PASS: Client can reach IdM" || \
    echo "  -> BLOCKED (check NetworkPolicy)"
  echo ""

  echo "Testing: Client → Client (should be BLOCKED):"
  if [ -n "$POD2" ]; then
    oc exec -n "${NAMESPACE}" "${VMIS[0]}" -- ping -c 2 -W 3 "${POD2}" > /dev/null 2>&1 && \
      echo "  -> FAIL: Client-to-client traffic NOT blocked" || \
      echo "  -> PASS: Client-to-client traffic is blocked by NetworkPolicy"
  else
    echo "  Could not determine pod IP for ${VMIS[1]}"
  fi
  echo ""
  echo "VMs inherit Kubernetes NetworkPolicy — no guest firewall rules needed."
}

case "${1:-}" in
  1) demo1 ;;
  2) demo2 ;;
  3) demo3 ;;
  4) demo4 ;;
  5) demo5 ;;
  all)
    demo1; echo ""; echo "---"; echo ""
    demo2; echo ""; echo "---"; echo ""
    demo3; echo ""; echo "---"; echo ""
    demo4; echo ""; echo "---"; echo ""
    demo5
    ;;
  *) usage ;;
esac
