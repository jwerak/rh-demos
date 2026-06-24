#!/bin/bash

# Only apply strict exit-on-error if the script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
fi

NAMESPACE="satellite-cloud-native"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../k8s/base" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${DEMO_PASSWORD:-}" ] && [ -f "${SCRIPT_DIR}/../.env" ]; then
  source "${SCRIPT_DIR}/../.env"
fi
: "${DEMO_PASSWORD:?DEMO_PASSWORD not set. Run: source .env}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=10"

# Source interactive demo framework
source "${SCRIPT_DIR}/demo-lib.sh"

# Run a command on a VM via virtctl port-forward + sshpass SSH
run_on_vm() {
  local vmi_name="$1"
  shift
  sshpass -p "${DEMO_PASSWORD}" ssh ${SSH_OPTS} \
    -o ProxyCommand="virtctl port-forward --stdio vmi/${vmi_name}.${NAMESPACE} 22" \
    cloud-user@localhost "$@"
}

# Print a copya ble SSH command for the user to run outside the script
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

usage() {
  echo "Usage: $0 <demo-id>"
  echo ""
  echo "Each section is independent — runs its own client VMs."
  echo ""
  echo "  Section A: Platform (VMs: client, client-pool)"
  echo "  a1  Zero-Touch Provisioning     - Deploy a single client, watch it auto-register"
  echo "  a2  Elastic Scaling             - Scale client pool from 0 to 5"
  echo "  a3  Self-Healing                - Kill a VM, watch it auto-recover"
  echo "  a4  IP-Agnostic Kerberos        - Prove Kerberos works with duplicate IPs"
  echo "  a5  Network Micro-Segmentation  - Verify SDN isolation between clients"
  echo "  a   Run all Platform demos"
  echo ""
  echo "  Section B: Compliance (VMs: sec-client, compliant-client)"
  echo "  b1  Manual OS Hardening         - fapolicyd + AIDE + auditor sudoers"
  echo "  b2  Automated Hardening (REX)   - Ansible playbook via Satellite"
  echo "  b3  RPM Whitelist Audit         - Package compliance check via Satellite"
  echo "      Usage: $0 b3 [audit|enforce]  (default: audit)"
  echo "  b4  CLI OpenSCAP Scan           - CIS L2 scan, download HTML report"
  echo "  b5  Satellite SCAP Dashboard    - Configure Satellite SCAP, view in UI"
  echo "  b6  CIS Remediation             - Apply CIS L2 fixes via Satellite REX"
  echo "  b7  Deploy Compliant Image      - Boot VM from CIS-hardened qcow2"
  echo "  b8  Compliance Verification     - Scan compliant image, compare scores"
  echo "  b   Run all Compliance demos"
  echo ""
  echo "  Section C: Lifecycle (VMs: lc-dev, lc-qa, lc-prod)"
  echo "  c1  Lifecycle Pipeline          - Dev → QA → Prod with 3 clients"
  echo "  c2  Package Upgrade Rollout     - demo-app v1.0 → v2.0 through environments"
  echo "  c3  Composite Content Views     - Add new packages, verify isolation"
  echo "  c   Run all Lifecycle demos"
  echo ""
  echo "  Utilities:"
  echo "  all    Run sections A + B in sequence"
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
  ssh_hint client "sudo tail -f /var/log/client-setup.log"
  echo ""
  echo "Verification (run after ~5 minutes):"
  ssh_hint client "sudo subscription-manager identity"
  ssh_hint idm "sudo bash -c 'echo \$DEMO_PASSWORD | kinit admin && ipa host-find'"
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
  ssh_hint satellite "sudo hammer host list --organization Demo_Org"
  echo ""
  echo "  # Check IdM sees all hosts"
  ssh_hint idm "sudo bash -c 'echo \$DEMO_PASSWORD | kinit admin && ipa host-find'"
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

  VMIS=($(oc get vmi -n "${NAMESPACE}" -l role=client -o jsonpath='{.items[*].metadata.name}' 2>/dev/null))

  if [ ${#VMIS[@]} -lt 2 ]; then
    echo "Need at least 2 client VMs. Scale the pool first: $0 2"
    return
  fi

  echo "Testing Kerberos on ${VMIS[0]}:"
  run_on_vm "${VMIS[0]}" "
    echo '--- Internal IP ---'
    ip addr show | grep 'inet 10\.'
    echo '--- Obtaining Kerberos ticket ---'
    echo '${DEMO_PASSWORD}' | kinit demouser 2>/dev/null
    echo '--- Ticket details ---'
    klist
  " 2>/dev/null || echo "  (VM not ready for Kerberos yet)"

  echo ""
  echo "Testing Kerberos on ${VMIS[1]}:"
  run_on_vm "${VMIS[1]}" "
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

  VMIS=($(oc get vmi -n "${NAMESPACE}" -l role=client -o jsonpath='{.items[*].metadata.name}' 2>/dev/null))

  if [ ${#VMIS[@]} -lt 2 ]; then
    echo "Need at least 2 client VMs. Scale the pool first: $0 2"
    return
  fi

  POD2=$(oc get "vmi/${VMIS[1]}" -n "${NAMESPACE}" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null)

  echo "Testing: Client → Satellite (should SUCCEED):"
  SAT_IP=$(oc get svc satellite -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
  run_on_vm "${VMIS[0]}" "curl -sk --connect-timeout 5 https://${SAT_IP}/ > /dev/null 2>&1" && \
    echo "  -> PASS: Client can reach Satellite" || \
    echo "  -> BLOCKED (check NetworkPolicy)"
  echo ""

  echo "Testing: Client → IdM (should SUCCEED):"
  IDM_IP=$(oc get svc idm -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
  run_on_vm "${VMIS[0]}" "curl -sk --connect-timeout 5 https://${IDM_IP}/ > /dev/null 2>&1" && \
    echo "  -> PASS: Client can reach IdM" || \
    echo "  -> BLOCKED (check NetworkPolicy)"
  echo ""

  echo "Testing: Client → Client (should be BLOCKED):"
  if [ -n "$POD2" ]; then
    run_on_vm "${VMIS[0]}" "ping -c 2 -W 3 ${POD2} > /dev/null 2>&1" && \
      echo "  -> FAIL: Client-to-client traffic NOT blocked" || \
      echo "  -> PASS: Client-to-client traffic is blocked by NetworkPolicy"
  else
    echo "  Could not determine pod IP for ${VMIS[1]}"
  fi
  echo ""
  echo "VMs inherit Kubernetes NetworkPolicy — no guest firewall rules needed."
}

demo6() {
  echo "============================================"
  echo "  Demo 6: Manual OS Hardening"
  echo "  (fapolicyd + AIDE + Auditor sudoers)"
  echo "============================================"
  echo ""
  echo "This demo shows manual security hardening on a single client VM."
  echo ""
  echo "Defense-in-depth reasoning:"
  echo "  - fapolicyd blocks execution of unapproved binaries (SHA-256 integrity)"
  echo "  - BUT an attacker with root access can simply disable fapolicyd"
  echo "  - So we also restrict privileges via sudoers: block rpm -i, dnf install,"
  echo "    and systemctl stop fapolicyd for the auditor role"
  echo "  - AIDE monitors file integrity to detect unauthorized changes"
  echo ""

  oc get vmi/client -n "${NAMESPACE}" > /dev/null 2>&1 || {
    echo "ERROR: Client VM not running. Deploy it first: $0 1"
    return 1
  }

  echo "--- Step 1/3: fapolicyd with SHA-256 integrity ---"
  echo ""
  echo "fapolicyd blocks execution of any binary not in the trust database."
  echo "SHA-256 integrity mode verifies file hashes, not just file size."
  echo ""
  run_on_vm client "sudo bash" <<'FAPOLICYD'
set -e
echo "Installing fapolicyd..."
rpm -q fapolicyd > /dev/null 2>&1 || dnf install -y fapolicyd

echo "Configuring SHA-256 integrity checking..."
sed -i "s/^integrity = .*/integrity = sha256/" /etc/fapolicyd/fapolicyd.conf

echo "Enabling filesystem mark for bind mounts..."
grep -q "^allow_filesystem_mark" /etc/fapolicyd/fapolicyd.conf \
  && sed -i "s/^allow_filesystem_mark = .*/allow_filesystem_mark = 1/" /etc/fapolicyd/fapolicyd.conf \
  || echo "allow_filesystem_mark = 1" >> /etc/fapolicyd/fapolicyd.conf

echo "Adding container runtime rules (runc)..."
cat > /etc/fapolicyd/rules.d/25-runc.rules <<RULES
allow perm=any pattern=ld_so exe=/usr/bin/runc : all
allow perm=any uid=0 pattern=ld_so exe=/runc : trust=1
RULES

echo "Regenerating compiled rules..."
fagenrules --load

echo "Enabling and starting fapolicyd..."
systemctl enable --now fapolicyd

echo ""
echo "Verification:"
systemctl is-active fapolicyd
grep "^integrity" /etc/fapolicyd/fapolicyd.conf
echo "fapolicyd is active with SHA-256 integrity."
FAPOLICYD

  echo ""
  echo "--- Step 2/3: AIDE file integrity monitoring ---"
  echo ""
  echo "AIDE creates a baseline of file checksums and detects any changes."
  echo "A daily cron job runs at 04:05 to check for modifications."
  echo ""
  run_on_vm client "sudo bash" <<'AIDE_SETUP'
set -e
echo "Installing AIDE..."
rpm -q aide > /dev/null 2>&1 || dnf install -y aide

if [ ! -f /var/lib/aide/aide.db.gz ]; then
  echo "Initializing AIDE database (this may take a minute)..."
  aide --init
  mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
  echo "AIDE database initialized."
else
  echo "AIDE database already exists, skipping init."
fi

echo "Setting up daily integrity check cron (04:05)..."
echo "05 4 * * * root /usr/sbin/aide --check >> /var/log/aide-check.log 2>&1" > /etc/cron.d/aide-check
chmod 644 /etc/cron.d/aide-check

echo ""
echo "Verification:"
ls -la /var/lib/aide/aide.db.gz
cat /etc/cron.d/aide-check
echo "AIDE is configured."
AIDE_SETUP

  echo ""
  echo "--- Step 3/3: Auditor sudoers (defense-in-depth) ---"
  echo ""
  echo "The auditor role (IdM/AD group Linux-Auditors) can check security"
  echo "status but CANNOT install packages, remove packages, or disable"
  echo "security services — even with sudo."
  echo ""
  run_on_vm client "sudo bash" <<'SUDOERS_SETUP'
set -e
echo "Creating sudoers profile for auditor role..."
cat > /etc/sudoers.d/auditor <<SUDOERS
# Vyhrazena prava pro roli auditora dle CIS L2
# Mapovano na IdM/AD skupinu "Linux-Auditors"

Cmnd_Alias AUDIT_RO = /usr/sbin/aide --check, \
    /usr/bin/fapolicyd-cli --dump-db, \
    /usr/bin/fapolicyd-cli --list, \
    /usr/bin/systemctl status fapolicyd, \
    /usr/bin/systemctl status aide*, \
    /usr/bin/journalctl -u fapolicyd, \
    /usr/bin/oscap *, \
    /usr/bin/journalctl *

Cmnd_Alias DANGEROUS = /usr/bin/systemctl stop fapolicyd, \
    /usr/bin/systemctl disable fapolicyd, \
    /usr/bin/rpm -i*, \
    /usr/bin/rpm -U*, \
    /usr/bin/dnf install*, \
    /usr/bin/dnf remove*

%Linux-Auditors ALL=(root) NOPASSWD: AUDIT_RO, !DANGEROUS
SUDOERS
chmod 440 /etc/sudoers.d/auditor

echo "Validating sudoers syntax..."
visudo -cf /etc/sudoers.d/auditor

echo ""
echo "Verification:"
cat /etc/sudoers.d/auditor
echo ""
echo "Auditor sudoers profile created."
SUDOERS_SETUP

  echo ""
  echo "=== Manual hardening complete ==="
  echo ""
  echo "Summary:"
  echo "  - fapolicyd: SHA-256 integrity, container runtime trusted"
  echo "  - AIDE: baseline initialized, daily cron at 04:05"
  echo "  - sudoers: Linux-Auditors group can audit but not modify"
  echo ""
  echo "Verify anytime:"
  ssh_hint client "sudo systemctl status fapolicyd"
  ssh_hint client "sudo aide --check"
  ssh_hint client "sudo cat /etc/sudoers.d/auditor"
}

demo7() {
  echo "=========================================================="
  echo "  Demo 7: Automated Hardening via Satellite REX"
  echo "  (Ansible: fapolicyd + AIDE + sudoers at scale)"
  echo "=========================================================="
  echo ""
  echo "This demo automates the manual hardening from Demo 6 using"
  echo "an Ansible playbook executed through Satellite Remote Execution."
  echo ""
  echo "The playbook uses RHEL System Roles:"
  echo "  - redhat.rhel_system_roles.fapolicyd"
  echo "  - redhat.rhel_system_roles.aide"
  echo "  - sudoers via ansible.builtin.copy with visudo validation"
  echo ""

  PLAYBOOK_DIR="${SCRIPT_DIR}/../playbooks"
  PLAYBOOK_PATH="${PLAYBOOK_DIR}/hardening.yml"
  if [ ! -f "${PLAYBOOK_PATH}" ]; then
    echo "ERROR: Playbook not found at ${PLAYBOOK_PATH}"
    return 1
  fi

  echo "--- Step 1: Preparing Satellite Ansible infrastructure ---"
  echo ""
  echo "Installing RHEL System Roles and syncing Ansible roles into Satellite..."
  echo "In the GUI: Configure → Ansible → Roles → Import"
  echo ""
  run_on_vm satellite "sudo bash -c '
    rpm -q rhel-system-roles > /dev/null 2>&1 || satellite-maintain packages install -y rhel-system-roles
    echo \"Syncing Ansible roles into Satellite...\"
    hammer ansible roles sync --proxy-id 1 2>/dev/null || true
    echo \"Available Ansible roles:\"
    hammer ansible roles list 2>/dev/null | head -20 || true
  '"
  echo ""

  echo "--- Step 2: Uploading hardening playbook to Satellite ---"
  echo ""
  run_on_vm satellite "sudo mkdir -p /opt/demo-playbooks"
  upload_to_vm satellite /opt/demo-playbooks/hardening.yml < "${PLAYBOOK_PATH}"
  echo "Playbook uploaded to Satellite:/opt/demo-playbooks/hardening.yml"
  echo ""

  echo "--- Step 3: Importing playbook as REX job template ---"
  echo ""
  echo "In the GUI: Configure → Job Templates → New Job Template"
  echo "  Provider: Ansible, Category: Security Hardening"
  echo ""
  run_on_vm satellite "sudo bash -c '
    if hammer job-template list --search '\"'\"'name=\"Demo: OS Hardening\"'\"'\"' 2>/dev/null | grep -q \"Demo: OS Hardening\"; then
      echo \"Job template already exists, updating...\"
      TEMPLATE_ID=\$(hammer job-template list --search '\"'\"'name=\"Demo: OS Hardening\"'\"'\"' 2>/dev/null | grep -oP \"^\\s*\\K\\d+\" | head -1)
      if [ -n \"\${TEMPLATE_ID}\" ]; then
        hammer job-template update --id \"\${TEMPLATE_ID}\" --file /opt/demo-playbooks/hardening.yml 2>/dev/null || true
      fi
    else
      echo \"Creating new Ansible job template...\"
      hammer job-template create \
        --name \"Demo: OS Hardening\" \
        --job-category \"Security Hardening\" \
        --provider-type Ansible \
        --file /opt/demo-playbooks/hardening.yml \
        --organizations \"Demo_Org\" \
        --locations \"Cloud\" 2>/dev/null || true
    fi
    echo \"\"
    echo \"Job templates in Security Hardening category:\"
    hammer job-template list --search '\"'\"'job_category=\"Security Hardening\"'\"'\"' 2>/dev/null || true
  '"
  echo ""

  echo "--- Step 4: Assigning Ansible roles to client hosts ---"
  echo ""
  echo "In the GUI: Hosts → All Hosts → Edit → Ansible Roles tab"
  echo ""
  run_on_vm satellite "sudo bash -c '
    for HOST in \$(hammer host list --search \"name ~ client\" --per-page 100 2>/dev/null | grep -oP \"[\\w.-]+client[\\w.-]+\"); do
      echo \"Assigning fapolicyd + aide roles to \${HOST}...\"
      hammer host ansible-roles assign \
        --host \"\${HOST}\" \
        --ansible-role-ids \$(hammer ansible roles list --search \"name ~ fapolicyd\" 2>/dev/null | grep -oP \"^\\d+\" | head -1),\$(hammer ansible roles list --search \"name ~ aide\" 2>/dev/null | grep -oP \"^\\d+\" | head -1) \
        2>/dev/null || echo \"  (roles may already be assigned or not found)\"
    done
  '" || true
  echo ""

  echo "--- Step 5: Executing playbook on all clients via Satellite REX ---"
  echo ""
  echo "In the GUI: Hosts → All Hosts → Select clients → Schedule Remote Job"
  echo "  Job category: Security Hardening"
  echo "  Job template: Demo: OS Hardening"
  echo ""
  run_on_vm satellite "sudo bash -c '
    hammer job-invocation create \
      --job-template \"Demo: OS Hardening\" \
      --search-query \"name ~ client\" \
      --organization \"Demo_Org\" \
      --async 2>/dev/null || true
  '"
  echo ""

  echo "--- Step 6: Monitoring ---"
  echo ""
  echo "Checking latest job status..."
  sleep 5
  run_on_vm satellite "sudo bash -c '
    JOB_ID=\$(hammer job-invocation list --order \"id DESC\" --per-page 1 2>/dev/null | grep -oP \"^\\s*\\K\\d+\" | head -1)
    if [ -n \"\${JOB_ID}\" ]; then
      echo \"Latest job invocation:\"
      hammer job-invocation info --id \"\${JOB_ID}\" 2>/dev/null || true
    fi
  '" || true
  echo ""

  echo "=== Automated hardening triggered ==="
  echo ""
  echo "View full results in the Satellite Web UI:"
  echo "  Monitor → Jobs → Security Hardening"
  echo ""
  echo "Or check a client directly:"
  ssh_hint client "sudo systemctl status fapolicyd"
  ssh_hint client "sudo aide --check"
}

demo8() {
  echo "=========================================================="
  echo "  Demo 8: RPM Package Whitelist Audit"
  echo "  (Ansible via Satellite REX)"
  echo "=========================================================="
  echo ""
  echo "This demo audits installed RPM packages against an approved"
  echo "whitelist. Unauthorized packages are detected and reported."
  echo ""

  AUDIT_MODE="${2:-audit}"
  if [ "${AUDIT_MODE}" != "audit" ] && [ "${AUDIT_MODE}" != "enforce" ]; then
    echo "ERROR: Invalid mode '${AUDIT_MODE}'. Use 'audit' or 'enforce'."
    return 1
  fi

  echo "Mode: ${AUDIT_MODE}"
  if [ "${AUDIT_MODE}" = "enforce" ]; then
    echo "WARNING: Enforce mode will REMOVE unauthorized packages from clients!"
    echo ""
  fi
  echo ""

  PLAYBOOK_DIR="${SCRIPT_DIR}/../playbooks"
  PLAYBOOK_PATH="${PLAYBOOK_DIR}/rpm-whitelist-audit.yml"
  WHITELIST_PATH="${PLAYBOOK_DIR}/files/rpm-whitelist.txt"

  if [ ! -f "${PLAYBOOK_PATH}" ]; then
    echo "ERROR: Playbook not found at ${PLAYBOOK_PATH}"
    return 1
  fi

  echo "--- Step 1: Uploading audit playbook and whitelist to Satellite ---"
  echo ""
  run_on_vm satellite "sudo mkdir -p /opt/demo-playbooks/files"
  upload_to_vm satellite /opt/demo-playbooks/rpm-whitelist-audit.yml < "${PLAYBOOK_PATH}"
  if [ -f "${WHITELIST_PATH}" ]; then
    upload_to_vm satellite /opt/demo-playbooks/files/rpm-whitelist.txt < "${WHITELIST_PATH}"
  fi
  echo "Playbook and whitelist uploaded to Satellite:/opt/demo-playbooks/"
  echo ""

  echo "--- Step 2: Importing as REX job template ---"
  echo ""
  echo "In the GUI: Configure → Job Templates → New Job Template"
  echo "  Provider: Ansible, Category: Security Audit"
  echo ""
  run_on_vm satellite "sudo bash -c '
    if hammer job-template list --search '\"'\"'name=\"Demo: RPM Whitelist Audit\"'\"'\"' 2>/dev/null | grep -q \"Demo: RPM Whitelist Audit\"; then
      echo \"Job template already exists.\"
    else
      echo \"Creating new Ansible job template...\"
      hammer job-template create \
        --name \"Demo: RPM Whitelist Audit\" \
        --job-category \"Security Audit\" \
        --provider-type Ansible \
        --file /opt/demo-playbooks/rpm-whitelist-audit.yml \
        --organizations \"Demo_Org\" \
        --locations \"Cloud\" 2>/dev/null || true
    fi
    echo \"\"
    echo \"Job templates in Security Audit category:\"
    hammer job-template list --search '\"'\"'job_category=\"Security Audit\"'\"'\"' 2>/dev/null || true
  '"
  echo ""

  echo "--- Step 3: Running audit on all clients (mode: ${AUDIT_MODE}) ---"
  echo ""
  echo "In the GUI: Hosts → All Hosts → Select clients → Schedule Remote Job"
  echo "  Job category: Security Audit"
  echo "  Job template: Demo: RPM Whitelist Audit"
  echo "  Input: rpm_audit_mode = ${AUDIT_MODE}"
  echo ""
  run_on_vm satellite "sudo bash -c '
    hammer job-invocation create \
      --job-template \"Demo: RPM Whitelist Audit\" \
      --search-query \"name ~ client\" \
      --organization \"Demo_Org\" \
      --inputs \"rpm_audit_mode=${AUDIT_MODE}\" \
      --async 2>/dev/null || true
  '"
  echo ""

  echo "--- Step 4: Checking results ---"
  echo ""
  echo "Checking latest job status..."
  sleep 10
  run_on_vm satellite "sudo bash -c '
    JOB_ID=\$(hammer job-invocation list --order \"id DESC\" --per-page 1 2>/dev/null | grep -oP \"^\\s*\\K\\d+\" | head -1)
    if [ -n \"\${JOB_ID}\" ]; then
      echo \"Latest job invocation:\"
      hammer job-invocation info --id \"\${JOB_ID}\" 2>/dev/null || true
      echo \"\"
      echo \"Output from first host:\"
      FIRST_HOST=\$(hammer host list --search \"name ~ client\" --per-page 1 2>/dev/null | grep -oP \"[\\w.-]+client[\\w.-]+\" | head -1)
      if [ -n \"\${FIRST_HOST}\" ]; then
        hammer job-invocation output --id \"\${JOB_ID}\" --host \"\${FIRST_HOST}\" 2>/dev/null || true
      fi
    fi
  '" || true
  echo ""

  echo "=== RPM whitelist audit complete ==="
  echo ""
  echo "Full audit report available in Satellite Web UI:"
  echo "  Monitor → Jobs → Security Audit"
  if [ "${AUDIT_MODE}" = "audit" ]; then
    echo ""
    echo "To remove unauthorized packages, run in enforce mode:"
    echo "  $0 8 enforce"
  fi
}

demo9() {
  echo "=========================================================="
  echo "  Demo 9: CLI OpenSCAP Compliance Scan (CIS Level 2)"
  echo "  (Scan a RHEL client, download HTML report)"
  echo "=========================================================="
  echo ""
  echo "This demo runs an OpenSCAP CIS Level 2 scan on a client VM"
  echo "and produces an interactive HTML report for browser viewing."
  echo ""

  local TARGET_VM="${2:-client}"

  echo "--- Step 1: Verifying SCAP tools on ${TARGET_VM} ---"
  echo ""
  run_on_vm_sudo "${TARGET_VM}" "
    rpm -q openscap-scanner scap-security-guide > /dev/null 2>&1 || \
      dnf install -y openscap-scanner scap-security-guide
    echo 'OpenSCAP version:' && oscap --version | head -1
  "
  echo ""

  echo "--- Step 2: Available CIS profiles ---"
  echo ""
  run_on_vm_sudo "${TARGET_VM}" "
    oscap info --profiles /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml 2>/dev/null | grep -i cis || true
  "
  echo ""

  SCAP_PROFILE="xccdf_org.ssgproject.content_profile_cis"
  SCAP_DS="/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml"

  echo "--- Step 3: Running CIS Level 2 scan ---"
  echo ""
  echo "Profile: ${SCAP_PROFILE}"
  echo "This takes 2-5 minutes..."
  echo ""

  SCAN_OUTPUT=$(run_on_vm_sudo "${TARGET_VM}" "
    oscap xccdf eval \
      --profile ${SCAP_PROFILE} \
      --report /tmp/cis-report-\$(hostname -s).html \
      --results-arf /tmp/cis-results-\$(hostname -s)-arf.xml \
      ${SCAP_DS} 2>&1 ; echo \"OSCAP_EXIT=\$?\"
  " 2>&1) || true

  OSCAP_RC=$(echo "${SCAN_OUTPUT}" | grep -oP 'OSCAP_EXIT=\K\d+' | tail -1)
  OSCAP_RC="${OSCAP_RC:-2}"

  if [ "${OSCAP_RC}" = "1" ]; then
    echo "ERROR: OpenSCAP scan failed with an internal error."
    echo "${SCAN_OUTPUT}" | tail -20
    return 1
  fi

  echo "${SCAN_OUTPUT}" | grep -E '(Rule|Pass|Fail|Title)' | tail -30
  echo ""

  PASS_COUNT=$(echo "${SCAN_OUTPUT}" | grep -c 'pass$' || true)
  FAIL_COUNT=$(echo "${SCAN_OUTPUT}" | grep -c 'fail$' || true)
  TOTAL=$((PASS_COUNT + FAIL_COUNT))
  if [ "${TOTAL}" -gt 0 ]; then
    PCT=$((PASS_COUNT * 100 / TOTAL))
    echo "=== Scan Summary ==="
    echo "  Passed: ${PASS_COUNT}"
    echo "  Failed: ${FAIL_COUNT}"
    echo "  Compliance: ${PCT}%"
  fi
  echo ""

  echo "--- Step 4: Download the HTML report ---"
  echo ""
  VM_HOSTNAME=$(run_on_vm "${TARGET_VM}" "hostname -s" 2>/dev/null) || VM_HOSTNAME="${TARGET_VM}"
  echo "Run this command to download the report:"
  echo ""
  echo "  sshpass -p \"\$DEMO_PASSWORD\" scp ${SSH_OPTS} \\"
  echo "    -o ProxyCommand=\"virtctl port-forward --stdio vmi/${TARGET_VM}.${NAMESPACE} 22\" \\"
  echo "    cloud-user@localhost:/tmp/cis-report-${VM_HOSTNAME}.html ./cis-report-${VM_HOSTNAME}.html"
  echo ""
  echo "Then open cis-report-${VM_HOSTNAME}.html in a browser."
  echo ""
  echo "=== CLI OpenSCAP scan complete ==="
}

demo10() {
  echo "=========================================================="
  echo "  Demo 10: Satellite SCAP Compliance Dashboard"
  echo "  (Configure Satellite OpenSCAP, view reports in UI)"
  echo "=========================================================="
  echo ""
  echo "This demo configures Satellite's OpenSCAP integration,"
  echo "creates a CIS Level 2 compliance policy, runs a scan,"
  echo "and displays results in the Satellite Web UI."
  echo ""

  echo "--- Step 1: Uploading SCAP content to Satellite ---"
  echo ""
  echo "In the GUI: Hosts → Compliance → SCAP Contents"
  echo ""
  run_on_vm satellite "sudo bash -c '
    echo \"Loading default SCAP Security Guide content...\"
    hammer scap-content bulk-upload --type default 2>/dev/null || true
    echo \"\"
    echo \"Available SCAP content:\"
    hammer scap-content list 2>/dev/null || true
  '"
  echo ""

  echo "--- Step 2: Importing SCAP client Ansible role ---"
  echo ""
  run_on_vm satellite "sudo bash -c '
    hammer ansible roles import --proxy-id 1 --role-names theforeman.foreman_scap_client 2>/dev/null || true
    hammer ansible variables import --proxy-id 1 2>/dev/null | tail -3
    echo \"SCAP client Ansible role imported.\"
  '" || true
  echo ""

  echo "--- Step 3: Creating CIS Level 2 compliance policy ---"
  echo ""
  echo "In the GUI: Hosts → Compliance → Policies → New Policy"
  echo ""
  run_on_vm satellite "sudo bash -c '
    SCAP_ID=\$(hammer --csv scap-content list 2>/dev/null | grep \"rhel9\" | head -1 | cut -d, -f1)
    if [ -z \"\${SCAP_ID}\" ]; then
      echo \"ERROR: No RHEL 9 SCAP content found. Trying all content...\"
      SCAP_ID=\$(hammer --csv scap-content list 2>/dev/null | tail -1 | cut -d, -f1)
    fi
    echo \"SCAP Content ID: \${SCAP_ID}\"

    if [ -n \"\${SCAP_ID}\" ]; then
      echo \"Available CIS profiles for RHEL 9:\"
      hammer --csv scap-content-profile list --per-page 200 2>/dev/null | grep \"rhel9 default\" | grep -i cis || true
      echo \"\"

      PROFILE_ID=\$(hammer --csv scap-content-profile list --per-page 200 2>/dev/null | grep \"rhel9 default\" | grep \"Level 2 - Server\" | head -1 | cut -d, -f1)
      echo \"CIS Profile ID: \${PROFILE_ID}\"

      if [ -n \"\${PROFILE_ID}\" ]; then
        if hammer --csv policy list 2>/dev/null | grep -q \"CIS Level 2 Server\"; then
          echo \"Policy already exists, updating...\"
        else
          hammer policy create \
            --name \"CIS Level 2 Server\" \
            --deploy-by ansible \
            --scap-content-id \"\${SCAP_ID}\" \
            --scap-content-profile-id \"\${PROFILE_ID}\" \
            --period weekly \
            --weekday monday \
            --organizations \"Demo_Org\" \
            --locations \"Cloud\" 2>/dev/null || true
          echo \"Policy created.\"
        fi
      else
        echo \"WARNING: CIS profile not found in SCAP content.\"
      fi
    fi
    echo \"\"
    echo \"Compliance policies:\"
    hammer policy list --organization \"Demo_Org\" 2>/dev/null || true

    echo \"\"
    echo \"Creating Script-type scan template for GUI (pull-mqtt)...\"
    POLICY_ID=\$(hammer --csv policy list --organization \"Demo_Org\" 2>/dev/null | grep \"CIS Level 2\" | head -1 | cut -d, -f1)
    cat > /tmp/scap-scan.sh <<SCANSCRIPT
#!/bin/bash
foreman_scap_client \${POLICY_ID}
SCANSCRIPT
    if ! hammer job-template list --search '\"'\"'name=\"CIS L2 Compliance Scan\"'\"'\"' 2>/dev/null | grep -q \"CIS L2\"; then
      hammer job-template create \
        --name \"CIS L2 Compliance Scan\" \
        --job-category \"Compliance\" \
        --provider-type script \
        --file /tmp/scap-scan.sh \
        --organizations \"Demo_Org\" \
        --locations \"Cloud\" 2>/dev/null || true
    else
      SCAN_TMPL_ID=\$(hammer job-template list --search '\"'\"'name=\"CIS L2 Compliance Scan\"'\"'\"' 2>/dev/null | grep -oP \"^\\s*\\K\\d+\" | head -1)
      hammer job-template update --id \"\${SCAN_TMPL_ID}\" --file /tmp/scap-scan.sh 2>/dev/null || true
    fi
    echo \"Compliance job templates:\"
    hammer job-template list --search '\"'\"'job_category=\"Compliance\"'\"'\"' 2>/dev/null || true
  '"
  echo ""

  echo "--- Step 4: Configuring SCAP client on clients ---"
  echo ""
  run_on_vm satellite "sudo bash -c '
    POLICY_ID=\$(hammer --csv policy list --organization \"Demo_Org\" 2>/dev/null | grep \"CIS Level 2\" | head -1 | cut -d, -f1)
    echo \"Policy ID: \${POLICY_ID}\"
    SAT_FQDN=\$(hostname -f)
    echo \"Satellite FQDN: \${SAT_FQDN}\"

    CLIENT_HOSTS=\$(hammer host list --search \"name ~ client\" --per-page 100 2>/dev/null | grep -oP \"[\\w.-]+client[\\w.-]+\" || true)
    for HOST in \${CLIENT_HOSTS}; do
      echo \"Assigning policy to \${HOST}...\"
      hammer policy update \
        --name \"CIS Level 2 Server\" \
        --hosts \"\${HOST}\" 2>/dev/null || true
      hammer host update \
        --name \"\${HOST}\" \
        --openscap-proxy-id 1 2>/dev/null || true
    done
  '" || true
  echo ""

  echo "--- Step 5: Configuring foreman_scap_client on all clients ---"
  echo ""
  POLICY_ID=$(run_on_vm satellite "sudo hammer --csv policy list --organization Demo_Org 2>/dev/null | grep 'CIS Level 2' | head -1 | cut -d, -f1" 2>/dev/null) || POLICY_ID=""
  SAT_HOST=$(run_on_vm satellite "hostname -f" 2>/dev/null) || SAT_HOST="${SAT_FQDN:-satellite}"
  echo "Policy ID: ${POLICY_ID}, Satellite: ${SAT_HOST}"
  echo ""

  if [ -n "${POLICY_ID}" ]; then
    for CLIENT_HOST in $(oc get vmi -n "${NAMESPACE}" -l role=client -o name 2>/dev/null | sed 's|virtualmachineinstance.kubevirt.io/||'); do
      echo "  Configuring ${CLIENT_HOST}..."
      run_on_vm_sudo "${CLIENT_HOST}" "
        rpm -q rubygem-foreman_scap_client > /dev/null 2>&1 || dnf install -y rubygem-foreman_scap_client 2>/dev/null || true
        mkdir -p /etc/foreman_scap_client
        cat > /etc/foreman_scap_client/config.yaml <<SCAPCFG
:server: '${SAT_HOST}'
:port: 9090
:ca_file: '/etc/rhsm/ca/katello-server-ca.pem'
:host_certificate: '/etc/pki/consumer/cert.pem'
:host_private_key: '/etc/pki/consumer/key.pem'
${POLICY_ID}:
  :profile: xccdf_org.ssgproject.content_profile_cis
  :content_path: /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
  :download_path: /compliance/policies/${POLICY_ID}/content
SCAPCFG
        echo 'configured.'
      " || true
    done
    echo ""

    echo "--- Step 6: Running compliance scan on all clients ---"
    echo ""
    for CLIENT_HOST in $(oc get vmi -n "${NAMESPACE}" -l role=client -o name 2>/dev/null | sed 's|virtualmachineinstance.kubevirt.io/||'); do
      echo "  Scanning ${CLIENT_HOST} (2-5 minutes)..."
      run_on_vm_sudo "${CLIENT_HOST}" "foreman_scap_client ${POLICY_ID}" || true
      echo ""
    done
  else
    echo "WARNING: Could not determine policy ID. Manual configuration needed."
    echo ""
  fi

  echo "=== Satellite SCAP integration configured ==="
  echo ""
  echo "View compliance reports in the Satellite Web UI:"
  SAT_URL=$(oc get route satellite-ui -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null) || SAT_URL="${SAT_FQDN}"
  echo "  https://${SAT_URL}"
  echo ""
  echo "Navigate to:"
  echo "  Hosts → Compliance → Policies   (see the CIS Level 2 Server policy)"
  echo "  Hosts → Compliance → Reports    (see per-host scan results)"
  echo "  Click a report → rule-by-rule breakdown with pass/fail/severity"
}

demo11() {
  echo "=========================================================="
  echo "  Demo 11: CIS Level 2 Remediation via Satellite REX"
  echo "  (Ansible playbook: curated CIS fixes)"
  echo "=========================================================="
  echo ""
  echo "This demo applies a curated set of CIS Level 2 fixes using"
  echo "an Ansible playbook executed through Satellite Remote Execution."
  echo ""
  echo "Fixes include: file permissions, auditd rules, sysctl hardening,"
  echo "SSH hardening, password policy, core dump restrictions, and more."
  echo ""

  REMEDIATE_SCRIPT="${SCRIPT_DIR}/cis-remediate.sh"
  if [ ! -f "${REMEDIATE_SCRIPT}" ]; then
    echo "ERROR: Remediation script not found at ${REMEDIATE_SCRIPT}"
    return 1
  fi

  echo "--- Step 1: Creating REX job template + distributing script ---"
  echo ""
  upload_to_vm satellite /tmp/cis-remediate.sh < "${REMEDIATE_SCRIPT}" 2>/dev/null || true
  run_on_vm satellite "sudo bash -c '
    if ! hammer job-template list --search '\"'\"'name=\"CIS L2 Remediation\"'\"'\"' 2>/dev/null | grep -q \"CIS L2\"; then
      hammer job-template create \
        --name \"CIS L2 Remediation\" \
        --job-category \"Compliance\" \
        --provider-type script \
        --file /tmp/cis-remediate.sh \
        --organizations \"Demo_Org\" \
        --locations \"Cloud\" 2>/dev/null || true
      echo \"Job template created.\"
    else
      TMPL_ID=\$(hammer job-template list --search '\"'\"'name=\"CIS L2 Remediation\"'\"'\"' 2>/dev/null | grep -oP \"^\\s*\\K\\d+\" | head -1)
      hammer job-template update --id \"\${TMPL_ID}\" --file /tmp/cis-remediate.sh 2>/dev/null || true
      echo \"Job template updated.\"
    fi
    hammer job-template list --search '\"'\"'job_category=\"Compliance\"'\"'\"' 2>/dev/null || true
  '" || true
  echo ""
  echo "In the GUI: Hosts → All Hosts → Select → Schedule Remote Job"
  echo "  Job category: Compliance"
  echo "  Job template: CIS L2 Remediation"
  echo ""
  for CLIENT_HOST in $(oc get vmi -n "${NAMESPACE}" -l role=client -o name 2>/dev/null | sed 's|virtualmachineinstance.kubevirt.io/||'); do
    upload_to_vm "${CLIENT_HOST}" /tmp/cis-remediate.sh < "${REMEDIATE_SCRIPT}" 2>/dev/null || true
    run_on_vm "${CLIENT_HOST}" "sudo chmod +x /tmp/cis-remediate.sh" 2>/dev/null || true
    echo "  Uploaded to ${CLIENT_HOST}"
  done
  echo ""

  echo "--- Step 2: Running remediation on client VMs ---"
  echo ""
  for CLIENT_HOST in $(oc get vmi -n "${NAMESPACE}" -l role=client -o name 2>/dev/null | sed 's|virtualmachineinstance.kubevirt.io/||'); do
    echo "  Remediating ${CLIENT_HOST}..."
    run_on_vm_sudo "${CLIENT_HOST}" "bash /tmp/cis-remediate.sh" || true
    echo ""
  done
  echo ""

  echo "=== CIS remediation complete ==="
  echo ""
  echo "Re-run the scan to see improvement:"
  echo "  $0 9          (CLI scan with HTML report)"
  echo "  $0 10         (Satellite compliance dashboard)"
  echo ""
  echo "Expected: compliance score improves from ~45% to ~55-65%"
}

demo12() {
  echo "=========================================================="
  echo "  Demo 12: Deploy CIS-Hardened VM Image"
  echo "  (Boot from pre-built Image Builder qcow2)"
  echo "=========================================================="
  echo ""
  echo "This demo deploys a RHEL 9 VM from a qcow2 image that was"
  echo "pre-hardened with CIS Level 2 profile using Image Builder."
  echo ""

  echo "--- Step 1: Checking CIS image availability ---"
  echo ""
  if ! oc get pvc cis-rhel9-base -n "${NAMESPACE}" > /dev/null 2>&1; then
    echo "ERROR: CIS base image PVC 'cis-rhel9-base' not found."
    echo ""
    echo "Upload the CIS-hardened qcow2 image first:"
    echo "  ${SCRIPT_DIR}/upload-cis-image.sh /path/to/cis-rhel9.qcow2"
    echo ""
    return 1
  fi
  echo "CIS base image PVC found:"
  oc get pvc cis-rhel9-base -n "${NAMESPACE}" -o wide
  echo ""

  echo "--- Step 2: Deploying compliant client VM ---"
  echo ""
  oc apply -f "${BASE_DIR}/compliant-client-vm.yaml"
  echo ""

  echo "--- Step 3: Watching VM lifecycle ---"
  echo ""
  echo "In the GUI: OpenShift Console → Virtualization → VirtualMachines"
  echo "  Watch: Provisioning → Starting → Running"
  echo ""
  oc get vmi/compliant-client -n "${NAMESPACE}" -w &
  WATCH_PID=$!
  sleep 3

  echo "Waiting for VM to reach Running state..."
  oc wait vmi/compliant-client -n "${NAMESPACE}" --for=jsonpath='{.status.phase}'=Running --timeout=300s 2>/dev/null || true
  kill $WATCH_PID 2>/dev/null || true
  echo ""

  echo "=== CIS-hardened VM deployed ==="
  echo ""
  echo "The VM is booting from a pre-hardened CIS Level 2 image."
  echo "Cloud-init will auto-register it to Satellite and IdM."
  echo ""
  echo "Monitor onboarding:"
  ssh_hint compliant-client "sudo tail -f /var/log/client-setup.log"
  echo ""
  echo "Check registration in:"
  echo "  Satellite UI → Hosts → All Hosts"
  echo "  IdM UI → Identity → Hosts"
  echo ""
  echo "Once registered, run Demo 13 to verify compliance score:"
  echo "  $0 13"
}

demo13() {
  echo "=========================================================="
  echo "  Demo 13: Compliance Verification"
  echo "  (Compare vanilla vs CIS-hardened image)"
  echo "=========================================================="
  echo ""
  echo "This demo scans the CIS-hardened VM and compares its compliance"
  echo "score against the vanilla client from Demo 9."
  echo ""

  echo "--- Step 1: Verifying compliant-client is ready ---"
  echo ""
  if ! oc get vmi/compliant-client -n "${NAMESPACE}" > /dev/null 2>&1; then
    echo "ERROR: compliant-client VM not found. Run Demo 12 first."
    return 1
  fi

  echo "Waiting for compliant-client to be accessible..."
  for i in $(seq 1 30); do
    run_on_vm compliant-client "echo ok" > /dev/null 2>&1 && break
    echo "  Attempt ${i}/30 — waiting for SSH..."
    sleep 10
  done
  echo "compliant-client is accessible."
  echo ""

  echo "--- Step 2: Installing SCAP tools on compliant-client ---"
  echo ""
  run_on_vm_sudo compliant-client "
    rpm -q openscap-scanner scap-security-guide > /dev/null 2>&1 || \
      dnf install -y openscap-scanner scap-security-guide
  " || true
  echo ""

  SCAP_PROFILE="xccdf_org.ssgproject.content_profile_cis"
  SCAP_DS="/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml"

  echo "--- Step 3: Running CIS scan on compliant-client ---"
  echo ""
  echo "This takes 2-5 minutes..."

  SCAN_CIS=$(run_on_vm_sudo compliant-client "
    oscap xccdf eval \
      --profile ${SCAP_PROFILE} \
      --report /tmp/cis-report-\$(hostname -s).html \
      --results-arf /tmp/cis-results-\$(hostname -s)-arf.xml \
      ${SCAP_DS} 2>&1 ; echo \"OSCAP_EXIT=\$?\"
  " 2>&1) || true

  CIS_PASS=$(echo "${SCAN_CIS}" | grep -c 'pass$' || true)
  CIS_FAIL=$(echo "${SCAN_CIS}" | grep -c 'fail$' || true)
  CIS_TOTAL=$((CIS_PASS + CIS_FAIL))
  CIS_PCT=0
  if [ "${CIS_TOTAL}" -gt 0 ]; then
    CIS_PCT=$((CIS_PASS * 100 / CIS_TOTAL))
  fi
  echo ""

  echo "--- Step 4: Uploading results to Satellite ---"
  echo ""
  POLICY_ID=$(run_on_vm satellite "sudo hammer --csv policy list --organization Demo_Org 2>/dev/null | grep 'CIS Level 2' | head -1 | cut -d, -f1" 2>/dev/null) || POLICY_ID=""
  SAT_HOST=$(run_on_vm satellite "hostname -f" 2>/dev/null) || SAT_HOST="${SAT_FQDN:-satellite}"

  if [ -n "${POLICY_ID}" ]; then
    echo "Uploading compliant-client scan to Satellite (policy ${POLICY_ID})..."
    run_on_vm_sudo compliant-client "
      mkdir -p /etc/foreman_scap_client
      cat > /etc/foreman_scap_client/config.yaml <<SCAPCFG
:server: '${SAT_HOST}'
:port: 9090
:ca_file: '/etc/rhsm/ca/katello-server-ca.pem'
:host_certificate: '/etc/pki/consumer/cert.pem'
:host_private_key: '/etc/pki/consumer/key.pem'
${POLICY_ID}:
  :profile: xccdf_org.ssgproject.content_profile_cis
  :content_path: /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
  :download_path: /compliance/policies/${POLICY_ID}/content
SCAPCFG
      foreman_scap_client ${POLICY_ID} 2>&1
    " || true

    echo ""
    echo "Uploading vanilla client scan to Satellite..."
    local vanilla_vm=""
    if oc get vmi/sec-client -n "${NAMESPACE}" > /dev/null 2>&1; then
      vanilla_vm="sec-client"
    elif oc get vmi/client -n "${NAMESPACE}" > /dev/null 2>&1; then
      vanilla_vm="client"
    fi
    if [ -n "${vanilla_vm}" ]; then
      run_on_vm_sudo "${vanilla_vm}" "foreman_scap_client ${POLICY_ID}" || true
    fi
    echo ""
  else
    echo "(Demo 10 not configured — skipping Satellite upload)"
    echo ""
  fi

  echo "--- Step 5: Comparison ---"
  echo ""

  VANILLA_PASS="N/A"
  VANILLA_FAIL="N/A"
  VANILLA_PCT="N/A"
  local vanilla_vm=""
  if oc get vmi/sec-client -n "${NAMESPACE}" > /dev/null 2>&1; then
    vanilla_vm="sec-client"
  elif oc get vmi/client -n "${NAMESPACE}" > /dev/null 2>&1; then
    vanilla_vm="client"
  fi
  if [ -n "${vanilla_vm}" ]; then
    SCAN_VANILLA=$(run_on_vm_sudo "${vanilla_vm}" "
      rpm -q openscap-scanner > /dev/null 2>&1 || dnf install -y openscap-scanner scap-security-guide > /dev/null 2>&1
      oscap xccdf eval \
        --profile ${SCAP_PROFILE} \
        ${SCAP_DS} 2>&1 ; echo \"OSCAP_EXIT=\$?\"
    " 2>&1) || true

    VANILLA_PASS=$(echo "${SCAN_VANILLA}" | grep -c 'pass$' || true)
    VANILLA_FAIL=$(echo "${SCAN_VANILLA}" | grep -c 'fail$' || true)
    VANILLA_TOTAL=$((VANILLA_PASS + VANILLA_FAIL))
    if [ "${VANILLA_TOTAL}" -gt 0 ]; then
      VANILLA_PCT="$((VANILLA_PASS * 100 / VANILLA_TOTAL))%"
    fi
    VANILLA_PASS="${VANILLA_PASS}"
    VANILLA_FAIL="${VANILLA_FAIL}"
  else
    echo "(No vanilla client VM running — showing CIS image results only)"
    echo ""
  fi

  echo "+---------------------------+-----------+-------------+"
  echo "| Metric                    | Vanilla   | CIS Image   |"
  echo "+---------------------------+-----------+-------------+"
  printf "| %-25s | %-9s | %-11s |\n" "Rules Passed" "${VANILLA_PASS}" "${CIS_PASS}"
  printf "| %-25s | %-9s | %-11s |\n" "Rules Failed" "${VANILLA_FAIL}" "${CIS_FAIL}"
  printf "| %-25s | %-9s | %-11s |\n" "Compliance" "${VANILLA_PCT}" "${CIS_PCT}%"
  echo "+---------------------------+-----------+-------------+"
  echo ""

  echo "--- Step 6: Download reports ---"
  echo ""
  CIS_HOSTNAME=$(run_on_vm compliant-client "hostname -s" 2>/dev/null) || CIS_HOSTNAME="compliant-client"
  echo "CIS-hardened VM report:"
  echo "  sshpass -p \"\$DEMO_PASSWORD\" scp ${SSH_OPTS} \\"
  echo "    -o ProxyCommand=\"virtctl port-forward --stdio vmi/compliant-client.${NAMESPACE} 22\" \\"
  echo "    cloud-user@localhost:/tmp/cis-report-${CIS_HOSTNAME}.html ./cis-report-${CIS_HOSTNAME}.html"
  echo ""
  echo "Open both reports in a browser for side-by-side comparison."
  echo ""

  SAT_URL=$(oc get route satellite-ui -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null) || SAT_URL="${SAT_FQDN}"
  echo "=== Compliance verification complete ==="
  echo ""
  echo "If Demo 10 was configured, view side-by-side in Satellite UI:"
  echo "  https://${SAT_URL}"
  echo "  Navigate to: Hosts → Compliance → Reports"
}

# --- Section B wrappers: ensure sec-client exists before compliance demos ---
# Demos b1-b6 use sec-client; b7 deploys compliant-client; b8 needs both.
# The original demo functions (demo6-demo13) reference "client" by name.
# We override TARGET_VM where supported, or deploy sec-client and let the
# function run against it.

ensure_sec_client() {
  ensure_vm sec-client "${BASE_DIR}/sec-client-vm.yaml"
}

# Section B uses sec-client as the target VM name for demos that accept it.
# For demos that hardcode "client", sec-client works because it has role:client.

demo_b1() { ensure_sec_client; SEC_VM=sec-client demo6_on sec-client; }
demo_b2() { ensure_sec_client; demo7; }
demo_b3() { ensure_sec_client; demo8 "$@"; }
demo_b4() { ensure_sec_client; demo9 "" sec-client; }
demo_b5() { ensure_sec_client; demo10; }
demo_b6() { ensure_sec_client; demo11; }
demo_b7() { demo12; }
demo_b8() { ensure_sec_client; demo13; }

# demo6 variant that targets a specific VM
demo6_on() {
  local target="${1:-client}"
  echo "============================================"
  echo "  Demo B1: Manual OS Hardening"
  echo "  (fapolicyd + AIDE + Auditor sudoers)"
  echo "============================================"
  echo ""
  echo "Target VM: ${target}"
  echo ""

  if ! oc get vmi/"${target}" -n "${NAMESPACE}" > /dev/null 2>&1; then
    echo "ERROR: ${target} VM not found."
    return 1
  fi

  echo "This demo shows manual security hardening on a single client VM."
  echo ""
  echo "Defense-in-depth reasoning:"
  echo "  - fapolicyd blocks execution of unapproved binaries (SHA-256 integrity)"
  echo "  - BUT an attacker with root access can simply disable fapolicyd"
  echo "  - So we also restrict privileges via sudoers: block rpm -i, dnf install,"
  echo "    systemctl stop fapolicyd for the auditor role."
  echo ""

  # Reuse demo6's logic but with the target VM
  echo "--- Layer 1: fapolicyd ---"
  echo ""
  run_on_vm_sudo "${target}" "
    dnf install -y fapolicyd 2>/dev/null || true
    systemctl enable --now fapolicyd
    sed -i 's/^integrity.*/integrity = sha256/' /etc/fapolicyd/fapolicyd.conf 2>/dev/null || true
    systemctl restart fapolicyd
    echo 'fapolicyd status:' && systemctl is-active fapolicyd
  " || true
  echo ""

  echo "--- Layer 2: AIDE ---"
  echo ""
  run_on_vm_sudo "${target}" "
    dnf install -y aide 2>/dev/null || true
    aide --init 2>/dev/null && mv -f /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz 2>/dev/null || true
    echo '05 4 * * * root /usr/sbin/aide --check' > /etc/cron.d/aide-check
    echo 'AIDE initialized, daily check at 04:05'
  " || true
  echo ""

  echo "--- Layer 3: Auditor sudoers ---"
  echo ""
  run_on_vm_sudo "${target}" "
    cat > /etc/sudoers.d/auditor <<'SUDOERS'
Cmnd_Alias AUDIT_RO = /usr/sbin/aide --check, /usr/bin/fapolicyd-cli --dump-db, /usr/bin/fapolicyd-cli --list, /usr/bin/systemctl status fapolicyd, /usr/bin/oscap *, /usr/bin/journalctl *
Cmnd_Alias DANGEROUS = /usr/bin/systemctl stop fapolicyd, /usr/bin/systemctl disable fapolicyd, /usr/bin/rpm -i*, /usr/bin/rpm -U*, /usr/bin/dnf install*, /usr/bin/dnf remove*
%Linux-Auditors ALL=(root) NOPASSWD: AUDIT_RO, !DANGEROUS
SUDOERS
    chmod 0440 /etc/sudoers.d/auditor
    visudo -cf /etc/sudoers.d/auditor && echo 'sudoers validated OK'
  " || true
  echo ""

  echo "=== Manual hardening complete on ${target} ==="
}

# =============================================================================
# Section C: Lifecycle Environment Demos
# =============================================================================

# Deploy a lifecycle VM for a specific environment.
# Templates cloud-init and VM manifests from lc-client-* templates.
deploy_lc_vm() {
  local env_name="$1"
  local reg_script="register-lc-${env_name}.sh"
  local vm_name="lc-${env_name}"

  if oc get vmi "${vm_name}" -n "${NAMESPACE}" > /dev/null 2>&1; then
    echo "  ${vm_name} already running"
    return 0
  fi

  local IPA_DOMAIN
  IPA_DOMAIN=$(echo "${IDM_FQDN}" | cut -d. -f2-)
  local IPA_REALM
  IPA_REALM=$(echo "${IPA_DOMAIN}" | tr '[:lower:]' '[:upper:]')

  sed -e "s|__LC_REG_URL__|http://${SAT_FQDN}/pub/${reg_script}|g" \
      -e "s|lc-client-cloudinit|lc-${env_name}-cloudinit|g" \
      -e "s|app: lc-client|app: lc-${env_name}|g" \
      -e "s|__IDM_FQDN__|${IDM_FQDN}|g" \
      -e "s|__SAT_FQDN__|${SAT_FQDN}|g" \
      -e "s|__IPA_DOMAIN__|${IPA_DOMAIN}|g" \
      -e "s|__IPA_REALM__|${IPA_REALM}|g" \
      -e "s|__DEMO_PASSWORD__|${DEMO_PASSWORD}|g" \
      "${BASE_DIR}/lc-client-cloudinit-secret.yaml" | oc apply -f -

  sed -e "s|lc-client|lc-${env_name}|g" \
      "${BASE_DIR}/lc-client-vm.yaml" | oc apply -f -

  echo "  ${vm_name} deployed (provisioning...)"
}

# Wait for a lifecycle VM to be ready (Running + SSH accessible)
wait_lc_vm() {
  local vm_name="$1"
  # Wait for DV clone
  local dv_name="${vm_name}-rootdisk"
  for i in $(seq 1 60); do
    local phase
    phase=$(oc get dv "${dv_name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "${phase}" = "Succeeded" ] && break
    [ "${phase}" = "" ] && break
    sleep 10
  done
  oc wait vmi/"${vm_name}" -n "${NAMESPACE}" --for=jsonpath='{.status.phase}'=Running --timeout=300s 2>/dev/null || true
  for i in $(seq 1 60); do
    run_on_vm "${vm_name}" "grep -qE '(Onboarding Finished|registration init script)' /var/log/client-setup.log 2>/dev/null" 2>/dev/null && break
    sleep 15
  done
}

# Build an RPM on the Satellite VM and upload it to the custom repo
build_and_upload_rpm() {
  local pkg_name="$1"
  local pkg_version="$2"
  local pkg_description="$3"

  run_on_vm satellite "sudo bash -c '
    REPO_ID=\$(hammer --csv repository list --product Demo-App --organization Demo_Org 2>/dev/null | tail -1 | cut -d, -f1)

    mkdir -p /tmp/${pkg_name}-rpm/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    cat > /tmp/${pkg_name}-rpm/SPECS/${pkg_name}.spec <<SPEC
Name:    ${pkg_name}
Version: ${pkg_version}
Release: 1%{?dist}
Summary: ${pkg_description}
License: MIT
BuildArch: noarch

%description
${pkg_description}

%install
mkdir -p %{buildroot}/usr/bin
cat > %{buildroot}/usr/bin/${pkg_name} <<SCRIPT
#!/bin/bash
echo \"${pkg_description} v${pkg_version} — managed via Red Hat Satellite\"
SCRIPT
chmod 755 %{buildroot}/usr/bin/${pkg_name}

%files
/usr/bin/${pkg_name}
SPEC
    rpmbuild --define \"_topdir /tmp/${pkg_name}-rpm\" -bb /tmp/${pkg_name}-rpm/SPECS/${pkg_name}.spec 2>&1 | tail -3

    RPM_FILE=\$(find /tmp/${pkg_name}-rpm/RPMS -name \"*.rpm\" | head -1)
    if [ -n \"\${RPM_FILE}\" ]; then
      echo \"Uploading \${RPM_FILE}...\"
      hammer repository upload-content \
        --id \"\${REPO_ID}\" \
        --path \"\${RPM_FILE}\" \
        --organization \"Demo_Org\" 2>&1 | tail -3
    fi
    rm -rf /tmp/${pkg_name}-rpm
  '"
}

# Section C: Lifecycle Management Demos
# These functions are sourced by demo-scenarios.sh. They rely on helpers
# defined there: run_on_vm, run_on_vm_sudo, upload_to_vm, deploy_lc_vm,
# wait_lc_vm, build_and_upload_rpm, and variables NAMESPACE, SAT_FQDN,
# IDM_FQDN, DEMO_PASSWORD, BASE_DIR, SCRIPT_DIR, SSH_OPTS.

demo_c1() {
  demo_section "Demo C1: Lifecycle Environments Pipeline (Dev -> QA -> Prod)"

  demo_info "This demo builds a complete content pipeline:"
  demo_info "  - Dev -> QA -> Prod lifecycle environments"
  demo_info "  - RHEL base + custom app composite content view"
  demo_info "  - Activation keys per environment"
  demo_info "  - 3 client VMs, one per environment"

  demo_step "Create lifecycle environments (Library -> Dev -> QA -> Prod)" \
    --gui "Content -> Lifecycle Environments -> Create Environment Path" \
    --cmd-satellite '
      for ENV_NAME in Dev QA Prod; do
        if hammer --csv lifecycle-environment list --organization Demo_Org 2>/dev/null | grep -q "${ENV_NAME}"; then
          echo "  ${ENV_NAME} already exists"
        else
          case ${ENV_NAME} in
            Dev)  PRIOR=Library ;;
            QA)   PRIOR=Dev ;;
            Prod) PRIOR=QA ;;
          esac
          hammer lifecycle-environment create \
            --name "${ENV_NAME}" \
            --prior "${PRIOR}" \
            --organization "Demo_Org" 2>/dev/null || true
          echo "  Created: ${ENV_NAME} (prior: ${PRIOR})"
        fi
      done
      echo ""
      echo "Lifecycle environment chain:"
      hammer lifecycle-environment list --organization Demo_Org 2>/dev/null' \
    --validate-satellite 'hammer --csv lifecycle-environment list --organization Demo_Org 2>/dev/null | grep -q Prod'

  demo_step "Create RHEL9-Lifecycle content view" \
    --gui "Content -> Content Views -> Create Content View" \
    --cmd-satellite '
      if hammer --csv content-view list --organization Demo_Org 2>/dev/null | grep -q RHEL9-Lifecycle; then
        echo "Content view RHEL9-Lifecycle already exists, skipping"
      else
        hammer content-view create \
          --name "RHEL9-Lifecycle" \
          --organization "Demo_Org" 2>/dev/null
        hammer content-view add-repository \
          --organization "Demo_Org" \
          --name "RHEL9-Lifecycle" \
          --repository-id 1 2>/dev/null || true
        hammer content-view add-repository \
          --organization "Demo_Org" \
          --name "RHEL9-Lifecycle" \
          --repository-id 2 2>/dev/null || true
        echo "Content view RHEL9-Lifecycle created with BaseOS (id:1) + AppStream (id:2)"
      fi' \
    --validate-satellite 'hammer --csv content-view list --organization Demo_Org 2>/dev/null | grep -q RHEL9-Lifecycle'

  demo_step "Create Demo-App product and repository" \
    --gui "Content -> Products -> Create Product" \
    --cmd-satellite '
      if hammer --csv product list --organization Demo_Org 2>/dev/null | grep -q Demo-App; then
        echo "Product Demo-App already exists"
      else
        hammer product create \
          --name "Demo-App" \
          --description "Demo application packages" \
          --organization "Demo_Org" 2>/dev/null
        echo "Product Demo-App created"
      fi
      if hammer --csv repository list --product Demo-App --organization Demo_Org 2>/dev/null | grep -q demo-app-rpms; then
        echo "Repository demo-app-rpms already exists"
      else
        hammer repository create \
          --name "demo-app-rpms" \
          --content-type yum \
          --product "Demo-App" \
          --organization "Demo_Org" 2>/dev/null
        echo "Repository demo-app-rpms created"
      fi' \
    --validate-satellite 'hammer --csv repository list --product Demo-App --organization Demo_Org 2>/dev/null | grep -q demo-app-rpms'

  demo_info "Building demo-app v1.0 RPM and uploading to Satellite..."
  demo_exec 'build_and_upload_rpm "demo-app" "1.0" "Demo Application"'

  demo_step "Create Demo-App-CV content view" \
    --gui "Content -> Content Views -> Create Content View" \
    --cmd-satellite '
      if hammer --csv content-view list --organization Demo_Org 2>/dev/null | grep -q Demo-App-CV; then
        echo "Content view Demo-App-CV already exists, skipping"
      else
        REPO_ID=$(hammer --csv repository list --product Demo-App --organization Demo_Org 2>/dev/null | tail -1 | cut -d, -f1)
        hammer content-view create \
          --name "Demo-App-CV" \
          --organization "Demo_Org" 2>/dev/null
        hammer content-view add-repository \
          --name "Demo-App-CV" \
          --repository-id "${REPO_ID}" \
          --organization "Demo_Org" 2>/dev/null
        echo "Content view Demo-App-CV created with demo-app-rpms repo"
      fi' \
    --validate-satellite 'hammer --csv content-view list --organization Demo_Org 2>/dev/null | grep -q Demo-App-CV'

  demo_step "Publish RHEL9-Lifecycle and Demo-App-CV" \
    --gui "Content -> Content Views -> Select -> Publish New Version" \
    --cmd-satellite '
      echo "Publishing RHEL9-Lifecycle..."
      hammer content-view publish \
        --name "RHEL9-Lifecycle" \
        --organization "Demo_Org" 2>&1 | tail -3
      echo "Publishing Demo-App-CV..."
      hammer content-view publish \
        --name "Demo-App-CV" \
        --organization "Demo_Org" 2>&1 | tail -3'

  demo_step "Create RHEL9-FullStack composite content view" \
    --gui "Content -> Content Views -> Create Content View -> Composite" \
    --cmd-satellite '
      if hammer --csv content-view list --organization Demo_Org 2>/dev/null | grep -q RHEL9-FullStack; then
        echo "Composite CV RHEL9-FullStack already exists, skipping"
      else
        hammer content-view create \
          --composite \
          --name "RHEL9-FullStack" \
          --organization "Demo_Org" 2>/dev/null
        echo "Composite content view RHEL9-FullStack created"
        echo "Adding component: RHEL9-Lifecycle (latest)..."
        LC_CV_ID=$(hammer --csv content-view list --organization Demo_Org 2>/dev/null | grep RHEL9-Lifecycle | head -1 | cut -d, -f1)
        hammer content-view component add \
          --composite-content-view "RHEL9-FullStack" \
          --component-content-view-id "${LC_CV_ID}" \
          --latest \
          --organization "Demo_Org" 2>/dev/null || true
        echo "Adding component: Demo-App-CV (latest)..."
        APP_CV_ID=$(hammer --csv content-view list --organization Demo_Org 2>/dev/null | grep Demo-App-CV | head -1 | cut -d, -f1)
        hammer content-view component add \
          --composite-content-view "RHEL9-FullStack" \
          --component-content-view-id "${APP_CV_ID}" \
          --latest \
          --organization "Demo_Org" 2>/dev/null || true
      fi' \
    --validate-satellite 'hammer --csv content-view list --organization Demo_Org 2>/dev/null | grep -q RHEL9-FullStack'

  demo_step "Publish RHEL9-FullStack composite" \
    --gui "Content -> Content Views -> RHEL9-FullStack -> Publish New Version" \
    --cmd-satellite '
      echo "Publishing RHEL9-FullStack..."
      hammer content-view publish \
        --name "RHEL9-FullStack" \
        --organization "Demo_Org" 2>&1 | tail -3
      echo ""
      echo "Composite content view versions:"
      hammer content-view version list \
        --content-view RHEL9-FullStack \
        --organization Demo_Org 2>/dev/null'

  demo_step "Promote RHEL9-FullStack to Dev, QA, Prod" \
    --gui "Content -> Content Views -> RHEL9-FullStack -> Versions -> Promote" \
    --cmd-satellite '
      LATEST_VER=$(hammer --csv content-view version list \
        --content-view RHEL9-FullStack \
        --organization Demo_Org \
        --order "version DESC" 2>/dev/null | head -2 | tail -1 | cut -d, -f3)
      echo "Promoting version ${LATEST_VER}..."
      for ENV in Dev QA Prod; do
        echo "  -> ${ENV}"
        hammer content-view version promote \
          --content-view "RHEL9-FullStack" \
          --version "${LATEST_VER}" \
          --to-lifecycle-environment "${ENV}" \
          --organization "Demo_Org" 2>&1 | tail -2
      done
      echo ""
      echo "Version distribution:"
      hammer content-view version list \
        --content-view RHEL9-FullStack \
        --organization Demo_Org 2>/dev/null'

  demo_step "Create activation keys per environment" \
    --gui "Content -> Activation Keys -> Create Activation Key" \
    --cmd-satellite '
      for ENV in dev qa prod; do
        AK_NAME="rhel9-lc-${ENV}"
        ENV_UPPER=$(echo "${ENV}" | sed "s/dev/Dev/;s/qa/QA/;s/prod/Prod/")
        if hammer --csv activation-key list --organization Demo_Org 2>/dev/null | grep -q "${AK_NAME}"; then
          echo "  ${AK_NAME} already exists"
        else
          hammer activation-key create \
            --name "${AK_NAME}" \
            --organization "Demo_Org" \
            --lifecycle-environment "${ENV_UPPER}" \
            --content-view "RHEL9-FullStack" \
            --unlimited-hosts 2>/dev/null
          echo "  Created: ${AK_NAME} (env: ${ENV_UPPER}, CV: RHEL9-FullStack)"
        fi
      done
      echo ""
      echo "Activation keys:"
      hammer activation-key list --organization Demo_Org 2>/dev/null'

  demo_step "Enable custom repo override on activation keys" \
    --cmd-satellite '
      for ENV in dev qa prod; do
        AK_NAME="rhel9-lc-${ENV}"
        echo "  Enabling Demo-App repo on ${AK_NAME}..."
        hammer activation-key content-override \
          --name "${AK_NAME}" \
          --content-label Demo_Org_Demo-App_demo-app-rpms \
          --override-name enabled \
          --value 1 \
          --organization "Demo_Org" 2>/dev/null || true
      done
      echo "Done."'

  demo_step "Generate per-environment registration scripts" \
    --cmd-satellite '
      for ENV in dev qa prod; do
        AK_NAME="rhel9-lc-${ENV}"
        echo "  Generating registration script for ${AK_NAME}..."
        REG_CMD=$(hammer host-registration generate-command \
          --activation-keys "${AK_NAME}" \
          --force true \
          --insecure true \
          --setup-remote-execution-pull true \
          --jwt-expiration 0 2>/dev/null)
        echo "${REG_CMD}" > /var/www/html/pub/register-lc-${ENV}.sh
        chmod 644 /var/www/html/pub/register-lc-${ENV}.sh
        echo "    Saved to /pub/register-lc-${ENV}.sh"
      done'

  demo_info "Deploying 3 lifecycle client VMs..."
  demo_exec 'deploy_lc_vm dev'
  demo_exec 'deploy_lc_vm qa'
  demo_exec 'deploy_lc_vm prod'

  demo_info "Waiting for VMs to register (this takes several minutes)..."
  demo_exec 'wait_lc_vm lc-dev; echo "  lc-dev is ready."'
  demo_exec 'wait_lc_vm lc-qa; echo "  lc-qa is ready."'
  demo_exec 'wait_lc_vm lc-prod; echo "  lc-prod is ready."'

  demo_step "Verify Satellite registration" \
    --gui "Hosts -> All Hosts (filter: name ~ lc-)" \
    --cmd-satellite 'echo "Lifecycle hosts:" && hammer host list --search "name ~ lc-" --organization Demo_Org 2>/dev/null || true'

  demo_step "Install and run demo-app on all environments" \
    --cmd 'for ENV in dev qa prod; do
      echo "  [lc-${ENV}] Installing demo-app..."
      run_on_vm_sudo "lc-${ENV}" "dnf install -y demo-app 2>&1 | tail -3" || true
      echo "  [lc-${ENV}] Running demo-app:"
      run_on_vm "lc-${ENV}" "demo-app 2>&1" || true
      echo ""
    done'

  demo_info "=== Lifecycle pipeline complete ==="
  local SAT_URL
  SAT_URL=$(oc get route satellite-ui -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null) || SAT_URL="${SAT_FQDN}"
  demo_info "Satellite UI: https://${SAT_URL}"
  demo_info "  Content -> Lifecycle Environments     (Dev -> QA -> Prod chain)"
  demo_info "  Content -> Content Views              (RHEL9-Lifecycle, Demo-App-CV, RHEL9-FullStack)"
  demo_info "  Content -> Activation Keys            (rhel9-lc-dev, rhel9-lc-qa, rhel9-lc-prod)"
  demo_info "  Hosts -> All Hosts                    (lc-dev, lc-qa, lc-prod)"
}

demo_c2() {
  demo_section "Demo C2: Content View Versioning & Promotion (demo-app v2.0 rollout)"

  demo_info "This demo shows controlled content rollout across environments:"
  demo_info "  - Build a new version of demo-app (v2.0)"
  demo_info "  - Promote to Dev first, verify, then QA, then Prod"
  demo_info "  - Each environment only sees the version promoted to it"

  demo_info "Building demo-app v2.0 RPM..."
  demo_exec 'build_and_upload_rpm "demo-app" "2.0" "Demo Application"'

  demo_step "Publish new Demo-App-CV version" \
    --gui "Content -> Content Views -> Demo-App-CV -> Publish New Version" \
    --cmd-satellite '
      echo "Publishing Demo-App-CV with demo-app v2.0..."
      hammer content-view publish \
        --name "Demo-App-CV" \
        --organization "Demo_Org" 2>&1 | tail -3
      echo ""
      echo "Demo-App-CV versions:"
      hammer content-view version list \
        --content-view Demo-App-CV \
        --organization Demo_Org 2>/dev/null'

  demo_step "Publish new RHEL9-FullStack composite version" \
    --gui "Content -> Content Views -> RHEL9-FullStack -> Publish (auto-pulls latest component versions)" \
    --cmd-satellite '
      echo "Publishing RHEL9-FullStack (pulls latest Demo-App-CV)..."
      hammer content-view publish \
        --name "RHEL9-FullStack" \
        --organization "Demo_Org" 2>&1 | tail -3'

  demo_step "Promote new RHEL9-FullStack to Dev ONLY" \
    --gui "Content -> Content Views -> RHEL9-FullStack -> Versions -> Promote to Dev" \
    --cmd-satellite '
      LATEST_VER=$(hammer --csv content-view version list \
        --content-view RHEL9-FullStack \
        --organization Demo_Org \
        --order "version DESC" 2>/dev/null | head -2 | tail -1 | cut -d, -f3)
      echo "Promoting version ${LATEST_VER} to Dev only..."
      hammer content-view version promote \
        --content-view "RHEL9-FullStack" \
        --version "${LATEST_VER}" \
        --to-lifecycle-environment "Dev" \
        --organization "Demo_Org" 2>&1 | tail -2'

  demo_step "Show version distribution across environments" \
    --gui "Content -> Content Views -> RHEL9-FullStack -> Versions" \
    --cmd-satellite '
      echo "RHEL9-FullStack versions and their environments:"
      hammer content-view version list \
        --content-view RHEL9-FullStack \
        --organization Demo_Org 2>/dev/null'

  demo_step "Verify Dev sees v2.0" \
    --gui "Hosts -> All Hosts -> lc-dev -> Content -> Packages" \
    --cmd 'run_on_vm_sudo lc-dev "dnf clean all > /dev/null 2>&1" || true
      echo "  [lc-dev] Checking for updates:"
      run_on_vm_sudo lc-dev "dnf check-update demo-app 2>&1" || true
      echo ""
      echo "  [lc-dev] Upgrading to v2.0:"
      run_on_vm_sudo lc-dev "dnf update -y demo-app 2>&1 | tail -5" || true
      echo "  [lc-dev] Running demo-app:"
      run_on_vm lc-dev "demo-app 2>&1" || true'

  demo_step "Verify Prod still has v1.0" \
    --cmd 'run_on_vm_sudo lc-prod "dnf clean all > /dev/null 2>&1" || true
      echo "  [lc-prod] Checking for updates (should show nothing):"
      run_on_vm_sudo lc-prod "dnf check-update demo-app 2>&1" || true
      echo "  [lc-prod] Current version:"
      run_on_vm lc-prod "demo-app 2>&1" || true'

  demo_step "Promote to QA" \
    --gui "Content -> Content Views -> RHEL9-FullStack -> Versions -> Promote to QA" \
    --cmd-satellite '
      LATEST_VER=$(hammer --csv content-view version list \
        --content-view RHEL9-FullStack \
        --organization Demo_Org \
        --order "version DESC" 2>/dev/null | head -2 | tail -1 | cut -d, -f3)
      echo "Promoting version ${LATEST_VER} to QA..."
      hammer content-view version promote \
        --content-view "RHEL9-FullStack" \
        --version "${LATEST_VER}" \
        --to-lifecycle-environment "QA" \
        --organization "Demo_Org" 2>&1 | tail -2'

  demo_step "Verify QA sees v2.0" \
    --cmd 'run_on_vm_sudo lc-qa "dnf clean all > /dev/null 2>&1" || true
      echo "  [lc-qa] Upgrading to v2.0:"
      run_on_vm_sudo lc-qa "dnf update -y demo-app 2>&1 | tail -5" || true
      echo "  [lc-qa] Running demo-app:"
      run_on_vm lc-qa "demo-app 2>&1" || true'

  demo_step "Promote to Prod" \
    --gui "Content -> Content Views -> RHEL9-FullStack -> Versions -> Promote to Prod" \
    --cmd-satellite '
      LATEST_VER=$(hammer --csv content-view version list \
        --content-view RHEL9-FullStack \
        --organization Demo_Org \
        --order "version DESC" 2>/dev/null | head -2 | tail -1 | cut -d, -f3)
      echo "Promoting version ${LATEST_VER} to Prod..."
      hammer content-view version promote \
        --content-view "RHEL9-FullStack" \
        --version "${LATEST_VER}" \
        --to-lifecycle-environment "Prod" \
        --organization "Demo_Org" 2>&1 | tail -2'

  demo_step "Verify Prod now has v2.0" \
    --cmd 'run_on_vm_sudo lc-prod "dnf clean all > /dev/null 2>&1" || true
      echo "  [lc-prod] Upgrading to v2.0:"
      run_on_vm_sudo lc-prod "dnf update -y demo-app 2>&1 | tail -5" || true
      echo "  [lc-prod] Running demo-app:"
      run_on_vm lc-prod "demo-app 2>&1" || true'

  demo_step "Final version comparison" \
    --cmd 'DEV_VER=$(run_on_vm lc-dev "demo-app 2>&1" 2>/dev/null) || DEV_VER="(unavailable)"
      QA_VER=$(run_on_vm lc-qa "demo-app 2>&1" 2>/dev/null) || QA_VER="(unavailable)"
      PROD_VER=$(run_on_vm lc-prod "demo-app 2>&1" 2>/dev/null) || PROD_VER="(unavailable)"
      echo "+-------------+------------------------------------------+"
      echo "| Environment | demo-app output                          |"
      echo "+-------------+------------------------------------------+"
      printf "| %-11s | %-40s |\n" "Dev"  "${DEV_VER}"
      printf "| %-11s | %-40s |\n" "QA"   "${QA_VER}"
      printf "| %-11s | %-40s |\n" "Prod" "${PROD_VER}"
      echo "+-------------+------------------------------------------+"
      echo ""
      echo "All 3 environments now run demo-app v2.0."'

  demo_info "=== Content view versioning & promotion complete ==="
  local SAT_URL
  SAT_URL=$(oc get route satellite-ui -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null) || SAT_URL="${SAT_FQDN}"
  demo_info "Satellite UI: https://${SAT_URL}"
  demo_info "  Content -> Content Views -> RHEL9-FullStack -> Versions"
  demo_info "    (see which version is in each environment)"
  demo_info "  Hosts -> All Hosts -> lc-dev / lc-qa / lc-prod"
  demo_info "    (see installed packages per host)"
}

demo_c3() {
  demo_section "Demo C3: Composite Content Views Deep Dive (add new content, watch it flow)"

  demo_info "This demo shows how adding new packages to a component CV"
  demo_info "flows through the composite to environments when published"
  demo_info "and promoted."

  demo_step "Show composite structure" \
    --gui "Content -> Content Views -> RHEL9-FullStack -> Content Views tab" \
    --cmd-satellite '
      echo "RHEL9-FullStack composite structure:"
      hammer content-view info \
        --name "RHEL9-FullStack" \
        --organization "Demo_Org" 2>/dev/null'

  demo_step "Show repos currently available on lc-dev" \
    --gui "Hosts -> All Hosts -> lc-dev -> Content -> Repository Sets" \
    --cmd-vm lc-dev "sudo dnf repolist 2>&1"

  demo_info "Building demo-lib v1.0 RPM and uploading to Satellite..."
  demo_info "Adding a new package to the existing Demo-App repository."
  demo_info "This simulates a team adding a new library to the app stack."
  demo_exec 'build_and_upload_rpm "demo-lib" "1.0" "Demo Library"'

  demo_step "Publish new Demo-App-CV version (now includes demo-lib)" \
    --gui "Content -> Content Views -> Demo-App-CV -> Publish New Version" \
    --cmd-satellite '
      echo "Publishing Demo-App-CV (now includes demo-lib)..."
      hammer content-view publish \
        --name "Demo-App-CV" \
        --organization "Demo_Org" 2>&1 | tail -3
      echo ""
      echo "Demo-App-CV versions:"
      hammer content-view version list \
        --content-view Demo-App-CV \
        --organization Demo_Org 2>/dev/null'

  demo_step "Publish new RHEL9-FullStack composite" \
    --gui "Content -> Content Views -> RHEL9-FullStack -> Publish (auto-pulls latest Demo-App-CV with demo-lib)" \
    --cmd-satellite '
      echo "Publishing RHEL9-FullStack (pulls latest Demo-App-CV)..."
      hammer content-view publish \
        --name "RHEL9-FullStack" \
        --organization "Demo_Org" 2>&1 | tail -3'

  demo_step "Promote to Dev only" \
    --gui "Content -> Content Views -> RHEL9-FullStack -> Versions -> Promote to Dev" \
    --cmd-satellite '
      LATEST_VER=$(hammer --csv content-view version list \
        --content-view RHEL9-FullStack \
        --organization Demo_Org \
        --order "version DESC" 2>/dev/null | head -2 | tail -1 | cut -d, -f3)
      echo "Promoting version ${LATEST_VER} to Dev only..."
      hammer content-view version promote \
        --content-view "RHEL9-FullStack" \
        --version "${LATEST_VER}" \
        --to-lifecycle-environment "Dev" \
        --organization "Demo_Org" 2>&1 | tail -2'

  demo_step "Install demo-lib on lc-dev (should succeed)" \
    --gui "Hosts -> All Hosts -> lc-dev -> Content -> Packages" \
    --cmd 'run_on_vm_sudo lc-dev "dnf clean all > /dev/null 2>&1" || true
      echo "  [lc-dev] Installing demo-lib:"
      run_on_vm_sudo lc-dev "dnf install -y demo-lib 2>&1 | tail -5" || true
      echo "  [lc-dev] Running demo-lib:"
      run_on_vm lc-dev "demo-lib 2>&1" || true'

  demo_step "Attempt demo-lib install on lc-prod (should fail)" \
    --cmd 'run_on_vm_sudo lc-prod "dnf clean all > /dev/null 2>&1" || true
      echo "  [lc-prod] Attempting to install demo-lib:"
      run_on_vm_sudo lc-prod "dnf install -y demo-lib 2>&1 | tail -5" || true
      echo ""
      echo "  Expected: \"No match for argument: demo-lib\" -- package not yet promoted to Prod."'

  demo_step "Promote to QA and Prod" \
    --gui "Content -> Content Views -> RHEL9-FullStack -> Versions -> Promote" \
    --cmd-satellite '
      LATEST_VER=$(hammer --csv content-view version list \
        --content-view RHEL9-FullStack \
        --organization Demo_Org \
        --order "version DESC" 2>/dev/null | head -2 | tail -1 | cut -d, -f3)
      for ENV in QA Prod; do
        echo "Promoting version ${LATEST_VER} to ${ENV}..."
        hammer content-view version promote \
          --content-view "RHEL9-FullStack" \
          --version "${LATEST_VER}" \
          --to-lifecycle-environment "${ENV}" \
          --organization "Demo_Org" 2>&1 | tail -2
      done
      echo ""
      echo "Final version distribution:"
      hammer content-view version list \
        --content-view RHEL9-FullStack \
        --organization Demo_Org 2>/dev/null'

  demo_step "Install demo-lib on lc-prod (should succeed now)" \
    --cmd 'run_on_vm_sudo lc-prod "dnf clean all > /dev/null 2>&1" || true
      echo "  [lc-prod] Installing demo-lib:"
      run_on_vm_sudo lc-prod "dnf install -y demo-lib 2>&1 | tail -5" || true
      echo "  [lc-prod] Running demo-lib:"
      run_on_vm lc-prod "demo-lib 2>&1" || true'

  demo_info "=== Composite content views deep dive complete ==="
  demo_info ""
  demo_info "Key takeaway: adding a package to a component CV (Demo-App-CV)"
  demo_info "only reaches client VMs when the composite (RHEL9-FullStack) is"
  demo_info "re-published and promoted to that environment."
  local SAT_URL
  SAT_URL=$(oc get route satellite-ui -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null) || SAT_URL="${SAT_FQDN}"
  demo_info "Satellite UI: https://${SAT_URL}"
  demo_info "  Content -> Content Views -> RHEL9-FullStack (composite)"
  demo_info "    -> Content Views tab (see component CVs)"
  demo_info "    -> Versions tab (see environment distribution)"
  demo_info "  Hosts -> All Hosts -> lc-dev / lc-prod"
  demo_info "    -> Content -> Packages (compare installed packages)"
}

# --- Section A wrappers: ensure platform VMs exist ---
demo_a1() { demo1; }
demo_a2() { demo2; }
demo_a3() { ensure_vm client "${BASE_DIR}/client-vm.yaml"; demo3; }
demo_a4() { ensure_pool client-pool 2; demo4; }
demo_a5() { ensure_pool client-pool 2; demo5; }

# --- Section runners ---
run_section_a() {
  demo_a1; echo ""; echo "---"; echo ""
  demo_a2; echo ""; echo "---"; echo ""
  demo_a3; echo ""; echo "---"; echo ""
  demo_a4; echo ""; echo "---"; echo ""
  demo_a5
}

run_section_c() {
  demo_c1; echo ""; echo "---"; echo ""
  demo_c2; echo ""; echo "---"; echo ""
  demo_c3
}

run_section_b() {
  demo_b1; echo ""; echo "---"; echo ""
  demo_b2; echo ""; echo "---"; echo ""
  demo_b3; echo ""; echo "---"; echo ""
  demo_b4; echo ""; echo "---"; echo ""
  demo_b5; echo ""; echo "---"; echo ""
  demo_b6; echo ""; echo "---"; echo ""
  demo_b7; echo ""; echo "---"; echo ""
  demo_b8
}

# Only execute the menu/demos automatically if the script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    # Section A: Platform
    a1|1) demo_a1 ;;
    a2|2) demo_a2 ;;
    a3|3) demo_a3 ;;
    a4|4) demo_a4 ;;
    a5|5) demo_a5 ;;
    a) run_section_a ;;

    # Section B: Compliance
    b1|6) demo_b1 ;;
    b2|7) demo_b2 ;;
    b3|8) demo_b3 "$@" ;;
    b4|9) demo_b4 ;;
    b5|10) demo_b5 ;;
    b6|11) demo_b6 ;;
    b7|12) demo_b7 ;;
    b8|13) demo_b8 ;;
    b) run_section_b ;;

    # Section C: Lifecycle
    c1) demo_c1 ;;
    c2) demo_c2 ;;
    c3) demo_c3 ;;
    c) run_section_c ;;

    # All sections
    all)
      run_section_a; echo ""; echo "==="; echo ""
      run_section_b
      ;;
    *) usage ;;
  esac
fi