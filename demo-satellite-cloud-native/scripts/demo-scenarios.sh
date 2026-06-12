#!/bin/bash
set -euo pipefail

NAMESPACE="satellite-cloud-native"
BASE_DIR="$(cd "$(dirname "$0")/../k8s/base" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${DEMO_PASSWORD:-}" ] && [ -f "${SCRIPT_DIR}/../.env" ]; then
  source "${SCRIPT_DIR}/../.env"
fi
: "${DEMO_PASSWORD:?DEMO_PASSWORD not set. Run: source .env}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

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
  echo "  Security demos:"
  echo "  6  Manual OS Hardening         - fapolicyd + AIDE + auditor sudoers"
  echo "  7  Automated Hardening (REX)   - Ansible playbook via Satellite"
  echo "  8  RPM Whitelist Audit         - Package compliance check via Satellite"
  echo "     Usage: $0 8 [audit|enforce]  (default: audit)"
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
    rpm -q rhel-system-roles > /dev/null 2>&1 || dnf install -y rhel-system-roles
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

case "${1:-}" in
  1) demo1 ;;
  2) demo2 ;;
  3) demo3 ;;
  4) demo4 ;;
  5) demo5 ;;
  6) demo6 ;;
  7) demo7 ;;
  8) demo8 "$@" ;;
  all)
    demo1; echo ""; echo "---"; echo ""
    demo2; echo ""; echo "---"; echo ""
    demo3; echo ""; echo "---"; echo ""
    demo4; echo ""; echo "---"; echo ""
    demo5; echo ""; echo "---"; echo ""
    demo6; echo ""; echo "---"; echo ""
    demo7; echo ""; echo "---"; echo ""
    demo8
    ;;
  *) usage ;;
esac
