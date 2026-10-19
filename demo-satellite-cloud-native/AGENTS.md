# demo-satellite-cloud-native

Canonical agent context for this directory. Cursor and Antigravity read `AGENTS.md`. `CLAUDE.md` is a symlink to this file for Claude Code.

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
- **Capsule VM** - Satellite Capsule 6.19, libvirt local profile only. Base packages come from the CDN via cloud-init (`capsule-userdata.j2`); the join is a separate play (`ansible/capsule-join.yml`) because `capsule-certs-generate` must run on the Satellite, which does not exist when cloud-init runs.
- **CentOS Stream 9 client** - libvirt local profile only. Content-only: no RHSM CDN step, no IdM, no `satellite-client-6` (there is no CentOS build), so no yggdrasil/REX-pull.

## Deployment Profiles

| Profile | Platform | Entry point | VMs |
|---|---|---|---|
| OpenShift | KubeVirt on OCP | `scripts/deploy.sh` | idm, satellite, clients |
| Remote KVM | libvirt over SSH | `scripts/deploy-libvirt.sh` + `.env` | idm, satellite, clients |
| **Local workstation** | libvirt on this machine | `scripts/deploy-local.sh` + `.env.local` | satellite, capsule, centos |

The local profile is the remote libvirt path with `LIBVIRT_HOST=localhost`: the deploy still goes over SSH, it just loops back, so `qemu+ssh://`, scp and the `ProxyCommand` hop to VMs are all unchanged. Switches: `DEMO_LOCAL_PROFILE=true`, `DEPLOY_IDM=false`, `DEPLOY_CAPSULE=true`. Deploy phases are strictly serial (Satellite -> Capsule base -> Capsule join); overlapping them would need 18 GB of concurrent guest RAM.

**The Capsule and CentOS client are libvirt-only by design** — `k8s/base/` deliberately has no manifests for them, and demo Section D refuses to run unless `DEMO_PLATFORM=libvirt`.

## Important Notes

- **DNS CNAMEs required:** `IDM_FQDN` and `SAT_FQDN` must be set in `.env`. These DNS names need CNAME records pointing to the OpenShift router wildcard (e.g., `idm.example.com CNAME idm.apps.<cluster>/`). The deploy script templates these into all manifests.
- **RHSM credentials secret required:** All VMs need a `rhsm-credentials` Kubernetes Secret mounted as a disk (serial: `rhsm-creds`). Create it with `./scripts/create-rhsm-secret.sh` before deploying.
- **Satellite manifest (optional):** For RPM content serving, upload a subscription manifest after Satellite installs via `./scripts/upload-manifest.sh`. Download from access.redhat.com -> Subscription Allocations (must have subscriptions attached). Without it, Satellite works for REX/lifecycle but won't serve packages. Repo sync takes ~10-60 min.
- **/etc/hosts mapping:** Each VM's `/etc/hosts` must map its FQDN to the real eth0 IP (10.0.2.2 in masquerade mode), NOT 127.0.0.1. IPA rejects loopback.
- **Client storage:** Clients need at least 30Gi storage (the RHEL 9 cloud image source PVC is ~30Gi).
- **Templated manifests:** Cloud-init secrets, routes, and client configs contain `__IDM_FQDN__`, `__SAT_FQDN__`, `__IPA_DOMAIN__`, `__IPA_REALM__` placeholders. Always deploy via `./scripts/deploy.sh` (not raw `oc apply`).

## Libvirt Gotchas

- **Never pass `-i {{ libvirt_host }},` or `delegate_to: "{{ libvirt_host }}"`.** With `LIBVIRT_HOST=localhost` Ansible resolves those to the implicit localhost (`connection: local`), so the task runs *inside the EE container* and silently does nothing on the host. Use `ansible/inventory/libvirt-host.yml` (host `hypervisor`) or the `libvirt-hypervisor` `add_host` shim in `libvirt-vm-delete.yml`.
- **Every new env var must be added to `environment-variables.pass` in `ansible/ansible-navigator.yml`.** A missing name is not an error — it arrives as an empty string inside the EE and shows up much later as a VM built with the wrong FQDN.
- **Extra disks start at `vdb`** (`vm.xml.j2` maps `extra_disks[0]` to `vd{{ "bcdefgh"[0] }}`). `satellite-userdata.j2` probes `/dev/vd{b,c,d,e,f}` with a >1 GiB filter, which is also correct on OpenShift where `vdb` is the small cloud-init disk.
- **`idm_ip` must be empty when IdM is skipped**, otherwise `network-config.j2` hands every client a nameserver that does not exist and nothing resolves. Both `libvirt-vm-create.yml` and the template guard for this.
- **`--cmd-satellite` / `--validate-satellite` snippets are wrapped in `sudo bash -c '...'`** (`demo-lib.sh:166`), so they must contain no single quotes. Use double quotes only.
- **Network XML changes do not apply to an existing network.** `libvirt-host-setup.yml` patches DHCP reservations with `virsh net-update`; adding the `<domain>` element needs a destroy/undefine/define cycle, which is refused while guests hold DHCP leases.
- **Custom repositories are disabled by default.** An activation key needs `hammer activation-key content-override --override-name enabled --value 1` per repo, with the content label derived from `hammer repository info --fields "Content label"` rather than hardcoded.
- **`hammer capsule` vs `hammer smart-proxy content`** has moved between 6.1x releases; Capsule content commands are written with an `||` fallback.
- **Always pass `virsh -c qemu:///system`** (use the `_virsh` helper in `platform-libvirt.sh`). `virsh` defaults to `qemu:///session` for a non-root user, so with `LIBVIRT_USER=jveverka` every `vm_exists` / `list_vms_by_role` lookup silently misses the demo VMs. The remote profile runs as root and never hit this.
- **Never let `delete_vm` glob a base image.** `libvirt-vm-delete.yml` matches `<vm_name>-*.qcow2`, which for the VM named `centos` also matches `centos-stream-9-x86_64-kvm.qcow2` — the shared backing file. A protected-paths list now excludes every `base_image` in `vm-profiles.yml`; keep it in sync when adding images.
- **`DEMO_PASSWORD` must be written to the env file with `export`.** The documented flow is `source .env && ./scripts/demo-scenarios.sh …`, and a bare assignment is not inherited by the child, which then falls back to its default env file and targets the wrong hypervisor.
- **The EE runs as root**, so `$HOME` is `/root` while the host cache is bind-mounted at `/home/runner/.cache/satellite-demo`. The VM registry path must prefer the mount, or every write is discarded inside the container.

## satellite-installer Gotchas (6.19)

Verified against `satellite-installer --scenario <s> --full-help` on this release:

- **`--disable-system-checks` does not exist.** The flag is `-s, --skip-checks-i-know-better`. An unrecognised option makes the installer exit with a usage error rather than ignore it, which strands cloud-init under `set -e`.
- **`--tuning` is valid for the `satellite` scenario but not for `capsule`.** The generated Capsule command probes `--full-help` and drops unsupported flags.
- **Never pass `--foreman-proxy-registration-url`.** `foreman_proxy_content` (`init.pp:184-190`) fails unless the URL host is in the certificate cnames, and `capsule-certs-generate` creates none: *"does not match the specified cname: []"*. The Registration feature is on by default; leave the URL unset and Puppet derives it.
- **The installer persists every option** into `scenarios.d/*-answers.yaml`, so a value from a failed run keeps being applied after you drop the flag. Use `--reset-<param>` to converge.
- **`capsule-certs-generate` output must be anchored carefully.** The command appears as `satellite-installer\` alone on one line with `--scenario capsule` on the next, while the surrounding prose also contains the literal string `satellite-installer --scenario capsule --help`. Match a line that is *only* `satellite-installer`, then assert the result starts correctly and passes `bash -n`.
- **Content requests land in `rhsm-pulpcore-https-443_access_ssl.log` on a Capsule** (not `foreman-ssl_access_ssl.log`), and `/var/log/httpd` is root-only so globs must expand under `sudo`.
- **`hammer --csv host list` field 4 is Host Group, not IP** (IP is field 5). Use `--fields ip`; an empty value makes `grep -c ""` match everything and invert a negative proof.
- **CentOS Stream 9 has no `dnf-plugin-subscription-manager`** — that is a RHEL 8 name; on el9 the plugin ships inside `subscription-manager`.

## Directory Structure

- `k8s/base/` - All Kubernetes manifests (VMs, services, cloud-init secrets, PVCs, network policies)
- `k8s/overlays/demo/` - Demo overlay (adds environment label)
- `scripts/deploy.sh` - Sequenced deployment (IdM first, then Satellite, then clients)
- `scripts/deploy-libvirt.sh` - Libvirt deployment; honours `DEMO_ENV_FILE`
- `scripts/deploy-local.sh` - Local workstation pre-flight, then hands over to `deploy-libvirt.sh`
- `ansible/capsule-join.yml` - Cross-VM Capsule join (certs-generate on Satellite, installer on Capsule)
- `ansible/templates/capsule-certs-generate.sh.j2` - Runs on the Satellite; distils the installer command `capsule-certs-generate` prints into one runnable line
- `scripts/verify-registration.sh` - Check Satellite + IdM + Capsule enrollment status
- `scripts/demo-scenarios.sh` - Run individual demos (sections a/b/c/d)
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
# Local workstation profile (Satellite + Capsule + CentOS client, no IdM)
cp .env.local.sample .env.local && $EDITOR .env.local
./scripts/deploy-local.sh             # ~90 min - 2.5 h

# Re-run one phase
cd ansible && ansible-navigator run deploy-all.yml --tags capsule
cd ansible && ansible-navigator run deploy-all.yml --tags capsule-join

# Use the local env with the other scripts
DEMO_ENV_FILE=.env.local ./scripts/verify-registration.sh
source .env.local && ./scripts/demo-scenarios.sh d
```

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

# Section D: Capsule (VMs: capsule, centos) — local libvirt profile only
./scripts/demo-scenarios.sh d1   # Capsule inventory and services
./scripts/demo-scenarios.sh d2   # Custom + upstream repos, CentOS client via the Capsule
./scripts/demo-scenarios.sh d3   # Prove the content path terminates at the Capsule
./scripts/demo-scenarios.sh d4   # Publish capsule-demo-app v2.0 and update the client
./scripts/demo-scenarios.sh d    # Run all Capsule demos

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
