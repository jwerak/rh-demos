# Cloud-Native RHEL Infrastructure on OpenShift Virtualization

Red Hat Satellite + IdM (FreeIPA) + RHEL clients running entirely as KubeVirt VMs on the OpenShift pod network. Zero Layer 2 networking, zero PXE — everything is cloud-init driven.

## Architecture

```
                  [ Kubernetes ClusterIP Services ]
             (satellite-svc)               (idm-svc)
                    |                          |
                    v                          v
          +-------------------+      +-------------------+
          |   Satellite VM    |      |      IdM VM       |
          |   4 vCPU, 22 Gi   |      |   2 vCPU, 4 Gi   |
          |   RHEL 9 + Sat 6  |      |   RHEL 9 + IPA   |
          +-------------------+      +-------------------+
                    ^                          ^
                    |  (Repo Sync & Content)   | (Kerberos/LDAP)
                    +-------------+------------+
                                  |
                   +--------------+--------------+
                   |  Default Pod Network (SDN)  |
                   |     Masquerade / OVN-K      |
                   +--------------+--------------+
                                  |
                                  v
                     +--------------------------+
                     |   RHEL Client VM Pool    |
                     |  1 vCPU, 2 Gi each       |
                     |  Auto-registered to both  |
                     +--------------------------+
```

## Prerequisites

- OpenShift 4.14+ with OpenShift Virtualization operator installed
- RHEL 9 cloud image available via DataImportCron (`rhel9` DataSource)
- Storage class supporting RWO PVCs (Ceph RBD, ODF, etc.)
- RHSM credentials (org ID + activation key) for all VMs
- Satellite subscription manifest ZIP (optional, for RPM content serving) — download from [console.redhat.com](https://console.redhat.com) -> Subscriptions -> Manifests
- DNS domain where you can create CNAME records (for Web UI access)
- `oc` CLI authenticated to the cluster
- `sshpass` installed locally (for SSH access to VMs via `virtctl port-forward`)

## Setup

### 1. Create DNS CNAME Records

The IdM and Satellite Web UIs are exposed via OpenShift Routes. For the UIs to work without redirect issues, the server FQDNs must match the Route hostnames. Create two CNAME records in your DNS domain pointing to the OpenShift router wildcard:

```
# Find your cluster's apps domain
oc get ingress.config cluster -o jsonpath='{.spec.domain}'
# Example output: apps.cluster-abc.dyn.redhatworkshops.io

# Create these CNAME records in your DNS:
idm.example.com        CNAME  idm.apps.cluster-abc.dyn.redhatworkshops.io
satellite.example.com  CNAME  satellite.apps.cluster-abc.dyn.redhatworkshops.io
```

The IdM server will be installed with `idm.example.com` as its FQDN, and the IPA Kerberos realm will be derived from your domain (e.g., `YOURDOMAIN.COM`). Client VMs get hostnames like `client-<id>.example.com` and are enrolled into this realm.

### 2. Configure Environment

```bash
cp .env.sample .env
```

Edit `.env` with your values:

```bash
# RHSM credentials (get from https://console.redhat.com/settings/connector/activation-keys)
export RHSM_ORG=12345678
export RHSM_ACTIVATION_KEY=your-activation-key

# DNS names matching the CNAMEs you created above
export IDM_FQDN=idm.example.com
export SAT_FQDN=satellite.example.com
```

### 3. Create the RHSM Credentials Secret

```bash
source .env
./scripts/create-rhsm-secret.sh
```

## Quick Start

```bash
source .env
./scripts/deploy.sh

# Monitor IdM install (~10 min)
# Monitor Satellite install (~20-30 min)
# The deploy script prints monitoring commands and Web UI URLs at the end

# Once infra is ready, scale client pool
oc scale vmpool client-pool -n satellite-cloud-native --replicas=2
```

The deploy script validates DNS resolution, checks for the RHSM secret, and substitutes your FQDNs into all manifests before applying them.

### (Optional) Satellite Subscription Manifest

If you want Satellite to serve RPM packages to clients (required for `dnf install` via Satellite repos), set `MANIFEST_PATH` in `.env` before running `deploy.sh`. The deploy script will wait for Satellite to finish installing (~20-30 min) and upload the manifest automatically.

If you didn't set `MANIFEST_PATH` before deploying, you can upload it later manually:

```bash
export MANIFEST_PATH=/path/to/manifest.zip
./scripts/upload-manifest.sh
```

Download your manifest from [access.redhat.com](https://access.redhat.com) -> Subscriptions -> Subscription Allocations. Make sure to **add subscriptions** to the allocation before exporting.

Without a manifest, Satellite still handles host lifecycle, REX, and Ansible — it just won't serve RPM content.

## Web UI Access

Both Satellite and IdM expose their web UIs via OpenShift Routes (TLS passthrough) using the DNS names you configured in `.env`. Your browser will show a certificate warning (self-signed certs) — accept it to proceed.

### URLs

- **Satellite:** `https://<SAT_FQDN>` (e.g., `https://satellite.veverak.net`)
- **IdM:** `https://<IDM_FQDN>` (e.g., `https://idm.veverak.net`)

### Satellite Web UI

- **Login:** `admin` / `<DEMO_PASSWORD>`
- Shows: registered hosts, content views, lifecycle environments, activation keys
- Navigate to **Hosts > All Hosts** to see enrolled RHEL clients
- Navigate to **Content > Lifecycle > Activation Keys** to see `rhel9-key`

### IdM (FreeIPA) Web UI

- **Login:** `admin` / `<DEMO_PASSWORD>`
- Shows: enrolled hosts, users, host groups, Kerberos policies
- Navigate to **Identity > Hosts** to see all auto-enrolled client VMs
- Navigate to **Identity > Users** to see the `demouser` account
- Navigate to **Identity > Host Groups** to see `satellite-clients`

### SSH Access to VMs

All VM access uses `virtctl port-forward` + SSH (the `oc exec vmi/` syntax requires a separate kubectl plugin):

```bash
# SSH via virtctl port-forward (requires sshpass + virtctl)
sshpass -p "$DEMO_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ProxyCommand="virtctl port-forward --stdio vmi/<vm-name>.satellite-cloud-native 22" \
  cloud-user@localhost

# The demo-scenarios.sh script provides helper functions you can source and use ad-hoc:
source scripts/demo-scenarios.sh

# ssh_exec <vm-name>           — open interactive SSH session to a VM
ssh_exec satellite
ssh_exec client

# run_on_vm <vm-name> "<cmd>"  — run a command and return output
run_on_vm satellite "sudo hammer host list"
run_on_vm client "sudo systemctl status fapolicyd"

# run_on_vm_sudo <vm-name> "<cmd>" — run as root
run_on_vm_sudo client "oscap xccdf eval --profile cis ..."

# Or use virtctl console for serial console access (no sshpass needed)
virtctl console vmi/idm -n satellite-cloud-native
# Login: cloud-user / see DEMO_PASSWORD in .env
```

## Demo Scenarios

### Demo 1: Zero-Touch Provisioning

Deploy a RHEL client that automatically registers to Satellite and enrolls in IdM — no manual configuration.

```bash
./scripts/demo-scenarios.sh 1

# Verify (after ~5 min):
oc exec -n satellite-cloud-native vmi/client -- subscription-manager identity
oc exec -n satellite-cloud-native vmi/idm -- bash -c "echo '$DEMO_PASSWORD' | kinit admin && ipa host-find"
```

### Demo 2: Elastic Scaling

Scale a pool of RHEL clients from 0 to 5 with a single command. Each VM auto-registers independently.

```bash
./scripts/demo-scenarios.sh 2

# Or manually:
oc scale vmpool client-pool -n satellite-cloud-native --replicas=5

# Verify all registered:
oc exec -n satellite-cloud-native vmi/satellite -- hammer host list --organization 'Demo_Org'
```

### Demo 3: Self-Healing

Delete a running VMI and watch OpenShift automatically recreate it, demonstrating platform resilience.

```bash
./scripts/demo-scenarios.sh 3

# Or manually:
oc delete vmi/client -n satellite-cloud-native
# Watch it come back:
oc get vmi -n satellite-cloud-native -w
```

### Demo 4: IP-Agnostic Kerberos

Prove that multiple VMs with identical internal NAT IPs (`10.0.2.x`) can each hold valid, independent Kerberos tickets.

```bash
./scripts/demo-scenarios.sh 4
```

The `noaddresses = true` setting in `/etc/krb5.conf` prevents Kerberos from binding tickets to the internal masquerade IP.

### Demo 5: Network Micro-Segmentation

Demonstrate that VMs inherit Kubernetes NetworkPolicy — client VMs can reach Satellite and IdM but cannot communicate with each other.

```bash
./scripts/demo-scenarios.sh 5
```

The `NetworkPolicy` allows `role: client` → `role: infra` traffic and blocks `role: client` → `role: client`.

### Demo 6: Manual OS Hardening

Step-by-step manual hardening of a single client VM showing the reasoning behind each layer of defense:

- **fapolicyd** — blocks execution of unapproved binaries using SHA-256 integrity checking
- **AIDE** — file integrity monitoring with daily cron checks
- **Sudoers** — restricted auditor role that can check security status but cannot install packages (`rpm -i`), remove packages, or disable security services (`systemctl stop fapolicyd`)

The defense-in-depth reasoning: fapolicyd prevents running unapproved binaries, but an attacker with root can disable it. Sudoers restrictions prevent the auditor role from doing so.

```bash
./scripts/demo-scenarios.sh 6

# Verify:
oc exec -n satellite-cloud-native vmi/client -- systemctl status fapolicyd
oc exec -n satellite-cloud-native vmi/client -- aide --check
oc exec -n satellite-cloud-native vmi/client -- cat /etc/sudoers.d/auditor
```

### Demo 7: Automated Hardening via Satellite REX

Automates everything from Demo 6 at scale using an Ansible playbook executed through Satellite Remote Execution. Uses RHEL System Roles (`redhat.rhel_system_roles.fapolicyd`, `redhat.rhel_system_roles.aide`) for certified, supported automation.

```bash
./scripts/demo-scenarios.sh 7

# The playbook is uploaded to Satellite and executed via REX on all clients.
# View results in Satellite Web UI: Monitor → Jobs → Security Hardening
```

The playbook is at `playbooks/hardening.yml` and can also be imported manually via the Satellite GUI: **Configure → Job Templates → New Job Template**.

### Demo 8: RPM Package Whitelist Audit

Audits installed RPM packages against an approved whitelist. Detects unauthorized package installations and can optionally remove them.

```bash
# Audit mode (default) — report only
./scripts/demo-scenarios.sh 8

# Enforce mode — remove unauthorized packages
./scripts/demo-scenarios.sh 8 enforce
```

The approved package list is in `playbooks/files/rpm-whitelist.txt`. To generate a baseline from a clean client:

```bash
oc exec -n satellite-cloud-native vmi/client -- rpm -qa --qf '%{NAME}\n' | sort -u > playbooks/files/rpm-whitelist.txt
```

### Demo 9: CLI OpenSCAP Compliance Scan

Runs an OpenSCAP CIS Level 2 scan on a client VM and generates an interactive HTML report. The scan runs directly on the VM via SSH; the HTML report can be downloaded via SCP and viewed in a browser.

```bash
./scripts/demo-scenarios.sh 9

# The script prints an SCP command to download the HTML report
# Open in a browser for a detailed, color-coded compliance breakdown
# Expected baseline: ~45% compliance on a vanilla RHEL 9 cloud image
```

### Demo 10: Satellite SCAP Compliance Dashboard

Configures Satellite's OpenSCAP integration end-to-end: imports SCAP content, creates a CIS Level 2 compliance policy, deploys the `foreman_scap_client` on all client VMs, and triggers a scan. Results are uploaded to Satellite and viewed in the Web UI.

The demo also creates a **"CIS L2 Compliance Scan"** Script-type job template (provider: `script`, category: Compliance). This template uses **pull-mqtt** (yggdrasil), so it can be triggered from the Satellite GUI even in this masquerade-networking architecture where Satellite cannot SSH to clients.

```bash
./scripts/demo-scenarios.sh 10

# View results in Satellite Web UI:
#   Hosts → Compliance → Policies  (see the CIS Level 2 Server policy)
#   Hosts → Compliance → Reports   (per-host scan results, rule-by-rule breakdown)

# To re-scan from the GUI:
#   Hosts → All Hosts → select host(s) → Schedule Remote Job
#   Job category: Compliance
#   Job template: CIS L2 Compliance Scan
```

> **Architecture note:** Ansible-type REX jobs use SSH push, which doesn't work in this masquerade-networking setup (Satellite can't resolve client FQDNs). All compliance job templates use the **Script provider** instead, which delivers jobs via **pull-mqtt** (yggdrasil) — the client pulls and executes the job locally, then uploads results back to Satellite.

### Demo 11: CIS Level 2 Remediation

Applies ~25 curated CIS Level 2 fixes to all client VMs: file permissions, auditd rules, sysctl network hardening, SSH hardening, password policy (pam_pwquality), core dump restrictions, login banners, cron hardening, and disabling unused services.

The demo creates a **"CIS L2 Remediation"** Script-type job template in Satellite, so the same remediation can be triggered from the GUI via pull-mqtt.

```bash
./scripts/demo-scenarios.sh 11

# Can also be triggered from Satellite UI:
#   Hosts → All Hosts → select host(s) → Schedule Remote Job
#   Job category: Compliance
#   Job template: CIS L2 Remediation

# Re-run Demo 9 or 10 after remediation to see improved compliance score (~45% → ~60%)
```

The remediation script is at `scripts/cis-remediate.sh`. It intentionally applies only safe, non-disruptive fixes to avoid breaking SSH access or VM connectivity in the demo environment.

### Demo 12: Deploy CIS-Hardened VM Image

Deploys a RHEL 9 VM from a qcow2 image pre-hardened with CIS Level 2 profile using Image Builder. The VM uses the same cloud-init as regular clients, so it auto-registers to Satellite and IdM.

```bash
# First, upload the CIS-hardened image (one-time):
./scripts/upload-cis-image.sh /path/to/cis-rhel9.qcow2

# Deploy the VM:
./scripts/demo-scenarios.sh 12

# Watch in OpenShift Console: Virtualization → VirtualMachines
# Check registration in Satellite UI: Hosts → All Hosts
# Check IdM enrollment: IdM UI → Identity → Hosts
```

### Demo 13: Compliance Verification

Scans both the vanilla client and the CIS-hardened VM, uploads results to Satellite, and prints a side-by-side comparison table. Demonstrates the dramatic difference between post-remediation compliance (~60%) and a purpose-built CIS image (~95%).

```bash
./scripts/demo-scenarios.sh 13

# Outputs a comparison table and SCP commands for both HTML reports
# Both scans are uploaded to Satellite — view side-by-side:
#   Satellite UI → Hosts → Compliance → Reports
```

## Resource Requirements

| VM | vCPUs | RAM | Storage |
|----|-------|-----|---------|
| IdM | 2 | 4 Gi | 30 Gi |
| Satellite | 4 | 22 Gi | 100 Gi root + 150 Gi data |
| Client (each) | 1 | 2 Gi | 30 Gi |
| Compliant Client | 1 | 2 Gi | 30 Gi |

**Total (infra + 2 clients + compliant):** 9 vCPUs, 32 Gi RAM, 370 Gi storage

## Project Structure

### Playbooks

```
playbooks/
├── hardening.yml              # Demo 7: fapolicyd + AIDE + sudoers (RHEL System Roles)
├── rpm-whitelist-audit.yml    # Demo 8: RPM package whitelist audit/enforce
├── oscap-scan.yml             # Demo 9: OpenSCAP CIS Level 2 scan (Ansible playbook)
├── oscap-remediate.yml        # Demo 11: CIS Level 2 remediation (Ansible playbook, reference)
└── files/
    └── rpm-whitelist.txt      # Approved RPM package list (Golden Image baseline)

scripts/
├── deploy.sh                  # Main deployment orchestrator
├── demo-scenarios.sh          # All demo scenarios (1-13)
├── upload-manifest.sh         # Satellite subscription manifest uploader
├── upload-cis-image.sh        # Upload CIS-hardened qcow2 image (Demo 12)
├── cis-remediate.sh           # CIS Level 2 remediation bash script (Demo 11)
├── verify-registration.sh     # Registration status checker
└── create-rhsm-secret.sh     # RHSM credentials secret creation
```

### Kustomize

```
k8s/
├── base/
│   ├── kustomization.yaml              # Resource list + common labels
│   ├── namespace.yaml                   # satellite-cloud-native
│   ├── idm-vm.yaml                      # IdM VirtualMachine
│   ├── idm-cloudinit-secret.yaml        # IdM cloud-init (ipa-server-install)
│   ├── idm-service.yaml                 # Kerberos, LDAP, HTTP/S ports
│   ├── idm-route.yaml                   # TLS passthrough for FreeIPA Web UI
│   ├── satellite-vm.yaml                # Satellite VirtualMachine
│   ├── satellite-cloudinit-secret.yaml  # Satellite cloud-init (satellite-installer)
│   ├── satellite-service.yaml           # HTTP/S, qdrouterd ports
│   ├── satellite-route.yaml             # TLS passthrough for Web UI
│   ├── satellite-data-pvc.yaml          # 150 Gi for /var/lib/pulp
│   ├── client-vm.yaml                   # Single RHEL client
│   ├── client-cloudinit-secret.yaml     # Client cloud-init (register + enroll)
│   ├── client-pool.yaml                 # VirtualMachinePool (starts at 0)
│   ├── compliant-client-vm.yaml         # CIS-hardened client VM (Demo 12)
│   └── network-policy.yaml              # Client isolation
└── overlays/
    └── demo/
        └── kustomization.yaml           # Adds environment: demo label
```

## Networking

All VMs use **masquerade mode** on the default pod network (OVN-Kubernetes):

- VMs get internal NAT addresses (`10.0.2.x` inside the guest)
- Inter-VM communication happens via Kubernetes ClusterIP Services
- External access to Satellite and IdM UIs via OpenShift Routes (TLS passthrough)
- No bridge networking, multus, or static IPs required

## Troubleshooting

### VM not starting
```bash
oc describe vm/<name> -n satellite-cloud-native
oc get events -n satellite-cloud-native --sort-by='.lastTimestamp'
```

### Cloud-init not running
```bash
oc console vmi/<name> -n satellite-cloud-native
# Login: cloud-user / see DEMO_PASSWORD in .env
# Check: cat /var/log/cloud-init-output.log
```

### Redeploying Satellite

Cloud-init only runs on first boot. To redeploy Satellite with updated cloud-init (e.g., after fixing the cloud-init secret), delete the VM and its storage, then re-run `deploy.sh`:

```bash
oc delete vm/satellite -n satellite-cloud-native
oc delete pvc/satellite-rootdisk satellite-pulp-data -n satellite-cloud-native
source .env
./scripts/deploy.sh
```

The deploy script uses `oc apply`, so it only recreates deleted resources — IdM, network policy, and client config are unaffected.

### Satellite installer failing
```bash
oc exec -n satellite-cloud-native vmi/satellite -- cat /var/log/satellite-setup.log
oc exec -n satellite-cloud-native vmi/satellite -- cat /var/log/foreman-installer/satellite.log
```

### IdM installer failing
```bash
oc exec -n satellite-cloud-native vmi/satellite -- cat /var/log/idm-setup.log
oc exec -n satellite-cloud-native vmi/idm -- cat /var/log/ipaserver-install.log
```

### Client not registering
```bash
oc exec -n satellite-cloud-native vmi/client -- cat /var/log/client-setup.log
oc exec -n satellite-cloud-native vmi/client -- subscription-manager status
oc exec -n satellite-cloud-native vmi/client -- ipa-client-install --uninstall  # retry
```

### DataVolume stuck importing
```bash
oc get dv -n satellite-cloud-native
oc describe dv/<name> -n satellite-cloud-native
```

## Clean Up

```bash
# Remove everything
oc delete -k k8s/overlays/demo/

# Or remove just clients
oc scale vmpool client-pool -n satellite-cloud-native --replicas=0
oc delete vm/client -n satellite-cloud-native
```

## Default Credentials

| Service | Username | Password |
|---------|----------|----------|
| Satellite Web UI | admin | `<DEMO_PASSWORD>` |
| IdM admin | admin | `<DEMO_PASSWORD>` |
| IdM Directory Manager | - | `<DEMO_PASSWORD>` |
| Demo user (IdM) | demouser | `<DEMO_PASSWORD>` |
| VM SSH (all VMs) | cloud-user | `<DEMO_PASSWORD>` |

> All services use the same password. Run `source .env` to load it, or check `.env` for the value.
>
> **Warning:** These are demo-only credentials. Do not use in production.

## References

- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
- [Red Hat Satellite Installation Guide](https://docs.redhat.com/en/documentation/red_hat_satellite)
- [Red Hat IdM Installation Guide](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/installing_identity_management)
- [KubeVirt VirtualMachinePool](https://kubevirt.io/user-guide/virtual_machines/pool/)
- [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
