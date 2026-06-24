#!/bin/bash
# Platform driver: libvirt
#
# Implements the same function interface as platform-openshift.sh but targets
# VMs running on a remote libvirt/KVM host, accessed via direct SSH.
#
# Expected variables from the sourcing script (demo-scenarios.sh):
#   DEMO_PASSWORD   - password for cloud-user on all VMs
#   SSH_OPTS        - common SSH options (StrictHostKeyChecking=no, etc.)
#
# Expected variables from .env:
#   LIBVIRT_HOST    - SSH-accessible libvirt hypervisor (e.g., fedora44.example.com)
#   LIBVIRT_USER    - SSH user on the libvirt host (default: root)
#   LIBVIRT_SSH_KEY - SSH private key for the libvirt host
#   LIBVIRT_NETWORK - libvirt network name (default: satellite-demo)

# --- Local configuration ---

: "${SSH_OPTS:=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=10}"

ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ansible" && pwd)"
VM_REGISTRY="${HOME}/.cache/satellite-demo/vm-registry.json"

# Ensure the cache directory exists
mkdir -p "$(dirname "${VM_REGISTRY}")"

# Defaults for optional variables
: "${LIBVIRT_USER:=root}"
: "${LIBVIRT_NETWORK:=satellite-demo}"

# SSH to a VM, proxied through the libvirt host (VMs are on NAT network)
_vm_ssh() {
  local vm_ip="$1"
  shift
  SSHPASS="${DEMO_PASSWORD}" sshpass -e ssh ${SSH_OPTS} \
    -o "ProxyCommand=ssh -o StrictHostKeyChecking=no -W %h:%p -i ${LIBVIRT_SSH_KEY} ${LIBVIRT_USER}@${LIBVIRT_HOST}" \
    "cloud-user@${vm_ip}" "$@"
}

# =============================================================================
# Internal helpers
# =============================================================================

# SSH to the libvirt hypervisor host for management commands (virsh, etc.)
_libvirt_ssh() {
  ssh ${SSH_OPTS} -i "${LIBVIRT_SSH_KEY}" "${LIBVIRT_USER}@${LIBVIRT_HOST}" "$@"
}

# Look up a VM's IP address. Tries the local registry first, falls back to
# virsh domifaddr on the remote host.
_libvirt_get_vm_ip() {
  local vm_name="$1"
  local ip=""

  # Try the local JSON registry first
  if [ -f "${VM_REGISTRY}" ]; then
    ip=$(python3 -c "
import json, sys
try:
    d = json.load(open('${VM_REGISTRY}'))
    print(d.get('${vm_name}', ''))
except Exception:
    pass
" 2>/dev/null)
  fi

  # Fall back to virsh domifaddr on the hypervisor
  if [ -z "${ip}" ]; then
    ip=$(_libvirt_ssh "virsh domifaddr '${vm_name}' --source agent 2>/dev/null \
      || virsh domifaddr '${vm_name}' 2>/dev/null" \
      | grep -oP '(\d{1,3}\.){3}\d{1,3}' | head -1)
  fi

  if [ -z "${ip}" ]; then
    echo "ERROR: Cannot determine IP for VM '${vm_name}'" >&2
    return 1
  fi

  echo "${ip}"
}

# =============================================================================
# Core functions (required by all demos)
# =============================================================================

# Run a command on a VM via SSH (proxied through the libvirt host).
# Usage: run_on_vm <vm_name> <cmd...>
run_on_vm() {
  local vm_name="$1"
  shift
  local vm_ip
  vm_ip=$(_libvirt_get_vm_ip "${vm_name}") || return 1
  _vm_ssh "${vm_ip}" "$@"
}

# Run a command as root on a VM.
# Usage: run_on_vm_sudo <vm_name> <cmd...>
run_on_vm_sudo() {
  local vm_name="$1"
  shift
  run_on_vm "${vm_name}" "sudo bash -c '$*'"
}

# Pipe stdin to a file on a VM (as root).
# Usage: echo "content" | upload_to_vm <vm_name> <dest_path>
upload_to_vm() {
  local vm_name="$1"
  local dest_path="$2"
  local vm_ip
  vm_ip=$(_libvirt_get_vm_ip "${vm_name}") || return 1
  _vm_ssh "${vm_ip}" "sudo bash -c 'cat > ${dest_path}'"
}

# Print a copyable SSH command for the user.
# Usage: ssh_hint <vm_name> <cmd>
ssh_hint() {
  local vm_name="$1"
  local cmd="$2"
  local vm_ip
  vm_ip=$(_libvirt_get_vm_ip "${vm_name}" 2>/dev/null) || vm_ip="<${vm_name}-ip>"
  echo "  sshpass -p \"\$DEMO_PASSWORD\" ssh ${SSH_OPTS} -o ProxyJump=${LIBVIRT_USER}@${LIBVIRT_HOST} cloud-user@${vm_ip} \"${cmd}\""
}

# Open an interactive SSH session to a VM.
# Usage: ssh_exec <vm_name>
ssh_exec() {
  local vm_name="$1"
  local vm_ip
  vm_ip=$(_libvirt_get_vm_ip "${vm_name}") || return 1
  _vm_ssh "${vm_ip}"
}

# =============================================================================
# Lifecycle functions (required by Section A demos)
# =============================================================================

# Ensure a VM exists and is running. Creates it via Ansible if missing,
# then waits for SSH readiness.
# Usage: ensure_vm <vm_name> <vm_profile>
ensure_vm() {
  local vm_name="$1"
  local vm_profile="$2"

  if vm_exists "${vm_name}"; then
    return 0
  fi

  echo "  Deploying ${vm_name} (profile: ${vm_profile})..."
  (cd "${ANSIBLE_DIR}" && ansible-navigator run libvirt-vm-create.yml \
    --extra-vars "vm_name=${vm_name} vm_profile=${vm_profile} libvirt_host=${LIBVIRT_HOST} libvirt_uri=qemu+ssh://${LIBVIRT_USER}@${LIBVIRT_HOST}/system")

  wait_vm_ready "${vm_name}"
  echo "  ${vm_name} is ready."
}

# Ensure a pool has at least N VMs. Creates missing ones with the "client" profile.
# Usage: ensure_pool <pool_name> <min_replicas>
ensure_pool() {
  local pool_name="$1"
  local min_replicas="$2"

  echo "  Ensuring ${pool_name} has at least ${min_replicas} replicas..."
  local i
  for i in $(seq 1 "${min_replicas}"); do
    local vm_name="${pool_name}-${i}"
    if ! vm_exists "${vm_name}"; then
      echo "  Creating ${vm_name}..."
      ensure_vm "${vm_name}" "client"
    fi
  done
}

# Check whether a VM exists on the libvirt host (any state: running or shut off).
# Usage: vm_exists <vm_name>
vm_exists() {
  local vm_name="$1"
  _libvirt_ssh "virsh list --all --name" 2>/dev/null | grep -q "^${vm_name}$"
}

# Delete a VM via Ansible.
# Usage: delete_vm <vm_name>
delete_vm() {
  local vm_name="$1"
  echo "  Deleting ${vm_name}..."
  (cd "${ANSIBLE_DIR}" && ansible-navigator run libvirt-vm-delete.yml \
    --extra-vars "vm_name=${vm_name} libvirt_host=${LIBVIRT_HOST} libvirt_uri=qemu+ssh://${LIBVIRT_USER}@${LIBVIRT_HOST}/system")

  # Remove from local registry
  if [ -f "${VM_REGISTRY}" ]; then
    python3 -c "
import json
try:
    d = json.load(open('${VM_REGISTRY}'))
    d.pop('${vm_name}', None)
    json.dump(d, open('${VM_REGISTRY}', 'w'), indent=2)
except Exception:
    pass
" 2>/dev/null || true
  fi
}

# Wait for a VM to become SSH-accessible and cloud-init to finish.
# Polls SSH until the cloud-init log shows completion markers.
# Usage: wait_vm_ready <vm_name>
wait_vm_ready() {
  local vm_name="$1"
  echo "  Waiting for ${vm_name} to become SSH-accessible..."

  local vm_ip=""
  # Poll until we can resolve the VM's IP (DHCP assignment may take a moment)
  for i in $(seq 1 30); do
    vm_ip=$(_libvirt_get_vm_ip "${vm_name}" 2>/dev/null) && [ -n "${vm_ip}" ] && break
    sleep 5
  done

  if [ -z "${vm_ip}" ]; then
    echo "  WARNING: Could not determine IP for ${vm_name} after 150s"
    return 1
  fi

  # Wait for SSH port to open
  for i in $(seq 1 60); do
    _vm_ssh "${vm_ip}" "echo ok" > /dev/null 2>&1 && break
    sleep 5
  done

  echo "  Waiting for ${vm_name} cloud-init to complete..."
  for i in $(seq 1 60); do
    _vm_ssh "${vm_ip}" \
      "grep -qE '(Onboarding Finished|Satellite Registration Complete|registration init script|Cloud-init .* finished)' /var/log/client-setup.log 2>/dev/null || \
       test -f /var/lib/cloud/instance/boot-finished" \
      > /dev/null 2>&1 && break
    sleep 15
  done
}

# List VMs matching a role prefix from the VM registry.
# Usage: list_vms_by_role <role>
#   role=client  -> matches client, client-pool-1, client-pool-2, sec-client, etc.
#   role=satellite -> matches satellite
#   role=idm -> matches idm
list_vms_by_role() {
  local role="$1"

  if [ -f "${VM_REGISTRY}" ]; then
    python3 -c "
import json, sys
try:
    d = json.load(open('${VM_REGISTRY}'))
    for name in sorted(d.keys()):
        if '${role}' in name:
            print(name)
except Exception:
    pass
" 2>/dev/null
  fi

  # Fall back to virsh on the remote host
  if [ ! -f "${VM_REGISTRY}" ] || [ ! -s "${VM_REGISTRY}" ]; then
    _libvirt_ssh "virsh list --all --name" 2>/dev/null | grep "${role}" || true
  fi
}

# Get a VM's IP address (public wrapper around _libvirt_get_vm_ip).
# Usage: get_vm_ip <vm_name>
get_vm_ip() {
  _libvirt_get_vm_ip "$1"
}

# Get the URL for a service (Satellite UI, IdM UI, etc.).
# On libvirt, services are accessed directly by VM IP -- no OpenShift Route needed.
# Usage: get_service_url <service_name>
get_service_url() {
  local service_name="$1"
  local vm_ip
  vm_ip=$(_libvirt_get_vm_ip "${service_name}" 2>/dev/null) || {
    echo "ERROR: Cannot determine IP for service '${service_name}'" >&2
    return 1
  }
  echo "https://${vm_ip}"
}
