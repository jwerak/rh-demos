#!/bin/bash
# platform-openshift.sh — OpenShift Virtualization platform driver
#
# Provides VM lifecycle primitives for KubeVirt VMs running on OpenShift.
# Sourced by demo-scenarios.sh (or other scripts); do NOT run directly.
#
# Required variables (set by the sourcing script):
#   NAMESPACE        — Kubernetes namespace for all resources
#   DEMO_PASSWORD    — SSH password for cloud-user on all VMs
#   SSH_OPTS         — Common SSH options (StrictHostKeyChecking, etc.)

# =============================================================================
# Extracted functions (moved verbatim from demo-scenarios.sh)
# =============================================================================

# Run a command on a VM via virtctl port-forward + sshpass SSH
run_on_vm() {
  local vmi_name="$1"
  shift
  sshpass -p "${DEMO_PASSWORD}" ssh ${SSH_OPTS} \
    -o ProxyCommand="virtctl port-forward --stdio vmi/${vmi_name}.${NAMESPACE} 22" \
    cloud-user@localhost "$@"
}

# Print a copyable SSH command for the user to run outside the script
ssh_hint() {
  local vmi_name="$1"
  local cmd="$2"
  echo "  sshpass -p \"\$DEMO_PASSWORD\" ssh ${SSH_OPTS} -o ProxyCommand=\"virtctl port-forward --stdio vmi/${vmi_name}.${NAMESPACE} 22\" cloud-user@localhost \"${cmd}\""
}

ssh_exec() {
  local vmi_name="$1"
  sshpass -p "${DEMO_PASSWORD}" ssh ${SSH_OPTS} -o ProxyCommand="virtctl port-forward --stdio vmi/${vmi_name}.${NAMESPACE} 22" cloud-user@localhost "${cmd}"
}

# Run a command as root on a VM
run_on_vm_sudo() {
  local vmi_name="$1"
  shift
  run_on_vm "${vmi_name}" "sudo bash -c '$*'"
}

# Pipe stdin to a file on a VM (as root)
upload_to_vm() {
  local vmi_name="$1"
  local dest_path="$2"
  sshpass -p "${DEMO_PASSWORD}" ssh ${SSH_OPTS} \
    -o ProxyCommand="virtctl port-forward --stdio vmi/${vmi_name}.${NAMESPACE} 22" \
    cloud-user@localhost "sudo bash -c 'cat > ${dest_path}'"
}

# Ensure a VM exists and is running. Deploys it if missing, waits for SSH.
# Usage: ensure_vm <vm-name> <yaml-file>
ensure_vm() {
  local vm_name="$1"
  local yaml_file="$2"
  if oc get vmi "${vm_name}" -n "${NAMESPACE}" > /dev/null 2>&1; then
    return 0
  fi
  echo "  Deploying ${vm_name}..."
  oc apply -f "${yaml_file}"
  echo "  Waiting for ${vm_name} to start..."
  # Wait for DV clone if needed
  local dv_name="${vm_name}-rootdisk"
  if oc get dv "${dv_name}" -n "${NAMESPACE}" > /dev/null 2>&1; then
    for i in $(seq 1 60); do
      local phase
      phase=$(oc get dv "${dv_name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)
      [ "${phase}" = "Succeeded" ] && break
      sleep 10
    done
  fi
  oc wait vmi/"${vm_name}" -n "${NAMESPACE}" --for=jsonpath='{.status.phase}'=Running --timeout=300s 2>/dev/null || true
  echo "  Waiting for ${vm_name} cloud-init to complete..."
  for i in $(seq 1 60); do
    run_on_vm "${vm_name}" "grep -qE '(Onboarding Finished|Satellite Registration Complete|registration init script)' /var/log/client-setup.log 2>/dev/null" 2>/dev/null && break
    sleep 15
  done
  echo "  ${vm_name} is ready."
}

# Ensure pool has at least N replicas
ensure_pool() {
  local pool_name="$1"
  local min_replicas="$2"
  local current
  current=$(oc get vmpool "${pool_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null) || current=0
  if [ "${current}" -lt "${min_replicas}" ]; then
    echo "  Scaling ${pool_name} to ${min_replicas} replicas..."
    oc scale vmpool "${pool_name}" -n "${NAMESPACE}" --replicas="${min_replicas}"
    sleep 5
    for vm in $(oc get vmi -n "${NAMESPACE}" -l "kubevirt.io/vmpool=${pool_name}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      oc wait vmi/"${vm}" -n "${NAMESPACE}" --for=jsonpath='{.status.phase}'=Running --timeout=300s 2>/dev/null || true
    done
  fi
}

# =============================================================================
# New wrapper functions
# =============================================================================

# Check if a VirtualMachineInstance exists
# Usage: vm_exists <vm-name>
# Returns 0 if the VMI exists, 1 otherwise.
vm_exists() {
  local vm_name="$1"
  oc get vmi "$vm_name" -n "$NAMESPACE" &>/dev/null
}

# Delete a VirtualMachine (not just the VMI — the whole VM object)
# Usage: delete_vm <vm-name>
delete_vm() {
  local vm_name="$1"
  oc delete vm "$vm_name" -n "$NAMESPACE"
}

# Wait for a VM to be running and cloud-init to complete.
# Reuses the same wait logic as ensure_vm but without the deploy step.
# Usage: wait_vm_ready <vm-name>
wait_vm_ready() {
  local vm_name="$1"
  # Wait for DV clone if needed
  local dv_name="${vm_name}-rootdisk"
  if oc get dv "${dv_name}" -n "${NAMESPACE}" > /dev/null 2>&1; then
    for i in $(seq 1 60); do
      local phase
      phase=$(oc get dv "${dv_name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)
      [ "${phase}" = "Succeeded" ] && break
      sleep 10
    done
  fi
  oc wait vmi/"${vm_name}" -n "${NAMESPACE}" --for=jsonpath='{.status.phase}'=Running --timeout=300s 2>/dev/null || true
  for i in $(seq 1 60); do
    run_on_vm "${vm_name}" "grep -qE '(Onboarding Finished|Satellite Registration Complete|registration init script)' /var/log/client-setup.log 2>/dev/null" 2>/dev/null && break
    sleep 15
  done
}

# List VMI names filtered by a role label
# Usage: list_vms_by_role <role>
# Example: list_vms_by_role client
list_vms_by_role() {
  local role="$1"
  oc get vmi -n "$NAMESPACE" -l "role=$role" -o jsonpath='{.items[*].metadata.name}'
}

# Get the pod-network IP address of a VMI
# Usage: get_vm_ip <vm-name>
get_vm_ip() {
  local vm_name="$1"
  oc get vmi "$vm_name" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}'
}

# Get the URL for a named service.
# Checks for an OpenShift Route first (returns https://host); if no route
# exists, falls back to the Service ClusterIP.
# Usage: get_service_url <service-name>
get_service_url() {
  local service_name="$1"
  local route_host
  route_host=$(oc get route "${service_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null)
  if [ -n "${route_host}" ]; then
    echo "https://${route_host}"
  else
    local cluster_ip
    cluster_ip=$(oc get svc "${service_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -n "${cluster_ip}" ]; then
      echo "${cluster_ip}"
    else
      echo "ERROR: no route or service '${service_name}' found in ${NAMESPACE}" >&2
      return 1
    fi
  fi
}
