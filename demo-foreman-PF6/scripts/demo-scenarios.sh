#!/bin/bash
set -euo pipefail

NAMESPACE="foreman-demo"
BASE_DIR="$(cd "$(dirname "$0")/../k8s/base" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${DEMO_PASSWORD:-}" ] && [ -f "${SCRIPT_DIR}/../.env" ]; then
  source "${SCRIPT_DIR}/../.env"
fi
: "${DEMO_PASSWORD:?DEMO_PASSWORD not set. Run: source .env}"
: "${FOREMAN_FQDN:?FOREMAN_FQDN not set. Run: source .env}"

FOREMAN_DOMAIN="${FOREMAN_FQDN#*.}"
FOREMAN_IMAGE="${FOREMAN_IMAGE:-quay.io/jwerak/foreman:latest}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

run_on_vm() {
  local vmi_name="$1"
  shift
  sshpass -p "${DEMO_PASSWORD}" ssh ${SSH_OPTS} \
    -o ProxyCommand="virtctl port-forward --stdio vmi/${vmi_name}.${NAMESPACE} 22" \
    cloud-user@localhost "$@"
}

ssh_hint() {
  local vmi_name="$1"
  local cmd="$2"
  echo "  sshpass -p \"\$DEMO_PASSWORD\" ssh ${SSH_OPTS} -o ProxyCommand=\"virtctl port-forward --stdio vmi/${vmi_name}.${NAMESPACE} 22\" cloud-user@localhost \"${cmd}\""
}

run_on_vm_sudo() {
  local vmi_name="$1"
  shift
  run_on_vm "${vmi_name}" "sudo bash -c '$*'"
}

foreman_api() {
  local endpoint="$1"
  shift
  curl -sk -u "admin:${DEMO_PASSWORD}" "https://${FOREMAN_FQDN}/api/v2${endpoint}" "$@"
}

apply_templated() {
  local file="$1"
  sed \
    -e "s|__FOREMAN_FQDN__|${FOREMAN_FQDN}|g" \
    -e "s|__FOREMAN_DOMAIN__|${FOREMAN_DOMAIN}|g" \
    -e "s|__FOREMAN_IMAGE__|${FOREMAN_IMAGE}|g" \
    -e "s|__DEMO_PASSWORD__|${DEMO_PASSWORD}|g" \
    "$file" | oc apply -f -
}

usage() {
  echo "Usage: $0 <demo-number>"
  echo ""
  echo "Demos:"
  echo "  1  Zero-Touch Provisioning  - Deploy a single client, watch it register to Foreman"
  echo "  2  Elastic Scaling          - Scale client pool from 0 to N"
  echo "  3  Self-Healing             - Kill a VM, watch it auto-recover"
  echo "  4  Foreman Host Management  - Show registered hosts and facts via API"
  echo "  5  Container Lifecycle      - podman-compose ops: logs, restart, status"
  echo ""
  echo "  all  Run all demos in sequence"
  exit 1
}

demo1() {
  echo "==========================================="
  echo "  Demo 1: Zero-Touch Provisioning"
  echo "==========================================="
  echo ""
  echo "Deploying a single RHEL client VM..."
  apply_templated "${BASE_DIR}/client-vm.yaml"
  echo ""

  echo "Watching VM boot (Ctrl+C to stop watching, VM continues in background)..."
  oc get vmi/client -n "${NAMESPACE}" -w &
  WATCH_PID=$!
  sleep 5

  echo ""
  echo "Waiting for client VM to be Running..."
  oc wait vmi/client -n "${NAMESPACE}" --for=jsonpath='{.status.phase}'=Running --timeout=300s 2>/dev/null || true
  kill "${WATCH_PID}" 2>/dev/null || true

  echo ""
  echo "Client VM is running. Cloud-init will:"
  echo "  1. Set hostname and /etc/hosts"
  echo "  2. Resolve Foreman via Kubernetes DNS"
  echo "  3. Wait for Foreman API"
  echo "  4. Register via Global Registration"
  echo ""
  echo "Monitor the client setup:"
  ssh_hint "client" "sudo tail -f /var/log/client-setup.log"
  echo ""
  echo "Check Foreman hosts after registration:"
  echo "  curl -sk -u admin:\$DEMO_PASSWORD https://${FOREMAN_FQDN}/api/v2/hosts | python3 -m json.tool"
}

demo2() {
  echo "==========================================="
  echo "  Demo 2: Elastic Scaling"
  echo "==========================================="
  echo ""

  CURRENT=$(oc get vmpool client-pool -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}')
  echo "Current pool replicas: ${CURRENT}"
  echo ""

  TARGET="${1:-2}"
  echo "Scaling client pool to ${TARGET} replicas..."
  oc scale vmpool client-pool -n "${NAMESPACE}" --replicas="${TARGET}"
  echo ""

  echo "Watching pool VMs..."
  oc get vmi -n "${NAMESPACE}" -l kubevirt.io/vmpool=client-pool -w &
  WATCH_PID=$!
  sleep 15

  echo ""
  echo "Current VMs:"
  oc get vmi -n "${NAMESPACE}" -l kubevirt.io/vmpool=client-pool
  kill "${WATCH_PID}" 2>/dev/null || true

  echo ""
  echo "Each pool VM will auto-register to Foreman once cloud-init completes."
  echo "Check registered hosts:"
  echo "  curl -sk -u admin:\$DEMO_PASSWORD https://${FOREMAN_FQDN}/api/v2/hosts | python3 -m json.tool"
}

demo3() {
  echo "==========================================="
  echo "  Demo 3: Self-Healing"
  echo "==========================================="
  echo ""

  echo "Current VMIs:"
  oc get vmi -n "${NAMESPACE}"
  echo ""

  echo "Deleting Foreman VMI (simulating node failure)..."
  oc delete vmi foreman -n "${NAMESPACE}"
  echo ""

  echo "Watching VM auto-recovery (runStrategy: Always)..."
  oc get vmi -n "${NAMESPACE}" -w &
  WATCH_PID=$!

  echo "Waiting for Foreman VM to recover..."
  sleep 10
  oc wait vmi/foreman -n "${NAMESPACE}" --for=jsonpath='{.status.phase}'=Running --timeout=300s 2>/dev/null || true
  kill "${WATCH_PID}" 2>/dev/null || true

  echo ""
  echo "Foreman VM recovered. podman-compose services will auto-start (systemd unit)."
  echo ""
  echo "Monitor service recovery:"
  ssh_hint "foreman" "sudo podman-compose -f /opt/foreman/docker-compose.yml ps"
}

demo4() {
  echo "==========================================="
  echo "  Demo 4: Foreman Host Management"
  echo "==========================================="
  echo ""

  echo "--- Organizations ---"
  foreman_api "/organizations" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for o in data.get('results', []):
    print(f\"  - {o['name']} (id: {o['id']})\")" 2>/dev/null || echo "  Could not query organizations API"
  echo ""

  echo "--- Locations ---"
  foreman_api "/locations" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for l in data.get('results', []):
    print(f\"  - {l['name']} (id: {l['id']})\")" 2>/dev/null || echo "  Could not query locations API"
  echo ""

  echo "--- Host Groups ---"
  foreman_api "/hostgroups" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for hg in data.get('results', []):
    title = hg.get('title', hg['name'])
    print(f\"  - {title} (id: {hg['id']})\")" 2>/dev/null || echo "  Could not query hostgroups API"
  echo ""

  echo "--- Users ---"
  foreman_api "/users" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for u in data.get('results', []):
    admin = ' [ADMIN]' if u.get('admin', False) else ''
    print(f\"  - {u['login']} ({u.get('firstname','')} {u.get('lastname','')}){admin}\")" 2>/dev/null || echo "  Could not query users API"
  echo ""

  echo "--- Registered Hosts ---"
  foreman_api "/hosts" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f\"Total hosts: {data.get('total', 0)}\")
for h in data.get('results', []):
    print(f\"  - {h['name']} (IP: {h.get('ip', 'N/A')}, OS: {h.get('operatingsystem_name', 'N/A')})\")" 2>/dev/null || echo "  Could not query hosts API"
  echo ""

  echo "--- Foreman Status ---"
  foreman_api "/status" | python3 -m json.tool 2>/dev/null || echo "  Could not query status API"
  echo ""

  echo "--- Dashboard ---"
  echo "  Web UI: https://${FOREMAN_FQDN}"
  echo "  Login:  admin / ${DEMO_PASSWORD}"
  echo "  Users:  alice (Manager), bob (Viewer), carol (Admin)"
}

demo5() {
  echo "==========================================="
  echo "  Demo 5: Container Lifecycle"
  echo "==========================================="
  echo ""

  echo "--- Running Containers ---"
  run_on_vm_sudo foreman "cd /opt/foreman && podman-compose ps"
  echo ""

  echo "--- Container Resource Usage ---"
  run_on_vm_sudo foreman "podman stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'"
  echo ""

  echo "--- Recent App Logs ---"
  run_on_vm_sudo foreman "cd /opt/foreman && podman-compose logs --tail=10 app" 2>/dev/null || true
  echo ""

  echo "Useful commands:"
  echo "  Restart all services:"
  ssh_hint "foreman" "sudo bash -c 'cd /opt/foreman && podman-compose restart'"
  echo "  View live logs:"
  ssh_hint "foreman" "sudo bash -c 'cd /opt/foreman && podman-compose logs -f app'"
  echo "  Stop/start:"
  ssh_hint "foreman" "sudo bash -c 'cd /opt/foreman && podman-compose down && podman-compose up -d'"
}

# --- Main ---
DEMO="${1:-}"
[ -z "${DEMO}" ] && usage

case "${DEMO}" in
  1) demo1 ;;
  2) demo2 "${2:-2}" ;;
  3) demo3 ;;
  4) demo4 ;;
  5) demo5 ;;
  all)
    for d in 1 2 3 4 5; do
      echo ""
      echo "Press Enter for Demo ${d} (or Ctrl+C to stop)..."
      read -r
      "demo${d}"
    done
    ;;
  *) usage ;;
esac
