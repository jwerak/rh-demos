# CLAUDE.md

Cloud-native Satellite + IdM demo: RHEL VMs running on OpenShift Virtualization with automated provisioning, identity management, and content management — all on the default pod network (masquerade mode).

## Components

- **IdM VM** (FreeIPA) - Identity server providing Kerberos/LDAP authentication. Installed via `ansible-freeipa` `ipaserver` role (RPM: `ansible-freeipa`), key vars: `ipaserver_ip_addresses`, `ipaserver_no_reverse: true`, `ipaserver_allow_zone_overlap: true`.
- **Satellite VM** - Red Hat Satellite 6.19 for content management and host lifecycle.
- **Client VM** - Single RHEL 9 client that auto-registers to both Satellite and IdM. Uses `ipa-client-install --force-join --force` (the `--force` flag allows CA cert download over HTTP without pre-existing trust).
- **Client Pool** (VirtualMachinePool) - Elastic pool of RHEL clients for scaling demos
- **NetworkPolicy** - SDN-based micro-segmentation blocking client-to-client traffic
- **Security Playbooks** - Ansible playbooks for OS hardening (fapolicyd, AIDE, sudoers) and RPM whitelist auditing, executed via Satellite REX
- **Compliance Scanning** - OpenSCAP CIS Level 2 scanning with Satellite SCAP integration, curated remediation, and compliant image deployment. Satellite GUI job templates use Script provider with **pull-mqtt** (yggdrasil) since Ansible-type REX can't SSH to clients in masquerade mode.
- **Compliant Client VM** - RHEL 9 VM booted from CIS Level 2 pre-hardened qcow2 image (Image Builder)

## Important Notes

- **DNS CNAMEs required:** `IDM_FQDN` and `SAT_FQDN` must be set in `.env`. These DNS names need CNAME records pointing to the OpenShift router wildcard (e.g., `idm.example.com CNAME idm.apps.<cluster>/`). The deploy script templates these into all manifests.
- **RHSM credentials secret required:** All VMs need a `rhsm-credentials` Kubernetes Secret mounted as a disk (serial: `rhsm-creds`). Create it with `./scripts/create-rhsm-secret.sh` before deploying.
- **Satellite manifest (optional):** For RPM content serving, upload a subscription manifest after Satellite installs via `./scripts/upload-manifest.sh`. Download from access.redhat.com -> Subscription Allocations (must have subscriptions attached). Without it, Satellite works for REX/lifecycle but won't serve packages. Repo sync takes ~10-60 min.
- **/etc/hosts mapping:** Each VM's `/etc/hosts` must map its FQDN to the real eth0 IP (10.0.2.2 in masquerade mode), NOT 127.0.0.1. IPA rejects loopback.
- **Client storage:** Clients need at least 30Gi storage (the RHEL 9 cloud image source PVC is ~30Gi).
- **Templated manifests:** Cloud-init secrets, routes, and client configs contain `__IDM_FQDN__`, `__SAT_FQDN__`, `__IPA_DOMAIN__`, `__IPA_REALM__` placeholders. Always deploy via `./scripts/deploy.sh` (not raw `oc apply`).

## Directory Structure

- `k8s/base/` - All Kubernetes manifests (VMs, services, cloud-init secrets, PVCs, network policies)
- `k8s/overlays/demo/` - Demo overlay (adds environment label)
- `scripts/deploy.sh` - Sequenced deployment (IdM first, then Satellite, then clients)
- `scripts/verify-registration.sh` - Check Satellite + IdM enrollment status
- `scripts/demo-scenarios.sh` - Run individual demos 1-13
- `scripts/upload-cis-image.sh` - Upload CIS-hardened qcow2 image for Demo 12
- `scripts/cis-remediate.sh` - CIS Level 2 remediation bash script (Demo 11)
- `playbooks/hardening.yml` - Ansible playbook: fapolicyd + AIDE + sudoers (RHEL System Roles)
- `playbooks/rpm-whitelist-audit.yml` - Ansible playbook: RPM package whitelist audit/enforce
- `playbooks/oscap-scan.yml` - Ansible playbook: OpenSCAP CIS Level 2 scan
- `playbooks/oscap-remediate.yml` - Ansible playbook: curated CIS Level 2 remediation
- `playbooks/files/rpm-whitelist.txt` - Approved RPM package list (Golden Image baseline)

## Kustomize Layout

```
k8s/base/           # namespace, IdM (vm + cloudinit + svc), Satellite (vm + cloudinit + svc + route + pvc),
                     # client (vm + cloudinit + pool), compliant-client-vm, network-policy
k8s/overlays/demo/   # Adds environment: demo label
```

## Key Commands

```bash
# Configure and deploy
cp .env.sample .env   # Edit with RHSM creds + DNS names
source .env
./scripts/create-rhsm-secret.sh
./scripts/deploy.sh                  # Templates FQDNs into manifests and applies
                                     # If MANIFEST_PATH is set, waits for Satellite and uploads it automatically
./scripts/upload-manifest.sh         # Or upload manifest manually after Satellite installs (~20-30 min)

# Ad-hoc VM access (source the script for helper functions)
source scripts/demo-scenarios.sh
ssh_exec satellite              # Interactive SSH session
ssh_exec client
run_on_vm satellite "sudo hammer host list"   # Run command, return output
run_on_vm_sudo client "systemctl status fapolicyd"

# Monitor IdM install
sshpass -p "$DEMO_PASSWORD" ssh -o StrictHostKeyChecking=no -o ProxyCommand="virtctl port-forward --stdio vmi/idm.satellite-cloud-native 22" cloud-user@localhost "sudo tail -f /var/log/idm-setup.log"

# Monitor Satellite install
sshpass -p "$DEMO_PASSWORD" ssh -o StrictHostKeyChecking=no -o ProxyCommand="virtctl port-forward --stdio vmi/satellite.satellite-cloud-native 22" cloud-user@localhost "sudo tail -f /var/log/satellite-setup.log"

# Deploy single client (Demo 1)
oc apply -f k8s/base/client-vm.yaml

# Scale client pool (Demo 2)
oc scale vmpool client-pool -n satellite-cloud-native --replicas=5

# Run demo scenarios
# Section A: Platform (VMs: client, client-pool)
./scripts/demo-scenarios.sh a1   # Zero-touch provisioning
./scripts/demo-scenarios.sh a2   # Elastic scaling
./scripts/demo-scenarios.sh a3   # Self-healing
./scripts/demo-scenarios.sh a4   # IP-agnostic Kerberos
./scripts/demo-scenarios.sh a5   # Network micro-segmentation
./scripts/demo-scenarios.sh a    # Run all Platform demos

# Section B: Compliance (VMs: sec-client, compliant-client)
./scripts/demo-scenarios.sh b1   # Manual OS hardening (fapolicyd + AIDE + sudoers)
./scripts/demo-scenarios.sh b2   # Automated hardening via Satellite REX
./scripts/demo-scenarios.sh b3   # RPM whitelist audit (audit mode)
./scripts/demo-scenarios.sh b3 enforce  # RPM whitelist audit (enforce mode)
./scripts/demo-scenarios.sh b4   # CLI OpenSCAP CIS L2 scan + HTML report
./scripts/demo-scenarios.sh b5   # Satellite SCAP compliance dashboard
./scripts/demo-scenarios.sh b6   # CIS Level 2 remediation
./scripts/demo-scenarios.sh b7   # Deploy CIS-hardened VM from qcow2 image
./scripts/demo-scenarios.sh b8   # Compliance verification (vanilla vs CIS image)
./scripts/demo-scenarios.sh b    # Run all Compliance demos

# Section C: Lifecycle (VMs: lc-client)
./scripts/demo-scenarios.sh c1   # Lifecycle environments pipeline (Dev → QA → Prod)
./scripts/demo-scenarios.sh c2   # Content view versioning & promotion
./scripts/demo-scenarios.sh c3   # Composite content views (RHEL + custom app)
./scripts/demo-scenarios.sh c    # Run all Lifecycle demos

# Old numeric IDs (1-13) still work as aliases

# Verify registrations
./scripts/verify-registration.sh

# Access Web UIs
echo "https://$(oc get route satellite-ui -n satellite-cloud-native -o jsonpath='{.spec.host}')"
# Satellite: admin / $DEMO_PASSWORD
echo "https://$(oc get route idm-ui -n satellite-cloud-native -o jsonpath='{.spec.host}')"
# IdM: admin / $DEMO_PASSWORD

# Cleanup
oc delete -k k8s/overlays/demo/
```

## Tools Required

- `oc` - OpenShift CLI (cluster must have OpenShift Virtualization operator)
- `kustomize` - manifest building (or use `oc apply -k`)

## Default Credentials (Demo Only)

| Service | Username | Password |
|---------|----------|----------|
| Satellite UI | admin | `<DEMO_PASSWORD>` |
| IdM admin | admin | `<DEMO_PASSWORD>` |
| IdM Directory Manager | - | `<DEMO_PASSWORD>` |
| IdM demo user | demouser | `<DEMO_PASSWORD>` |
| VM SSH (all) | cloud-user | `<DEMO_PASSWORD>` |

> All services use the same password. Run `source .env` to load it, or check `.env` for the value.
