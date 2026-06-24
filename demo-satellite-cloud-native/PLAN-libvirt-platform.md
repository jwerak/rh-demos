# Adoption Plan: Multi-Platform Support (Libvirt on Fedora 44)

## Goal

Add a second deployment platform to demo-satellite-cloud-native: a remote libvirt/KVM host (Fedora 44) accessible via SSH. The platform choice is configured in `.env`, and all provisioning is automated via Ansible (ansible-navigator + custom execution environment). The demo framework (`demo-lib.sh` + `demo-scenarios.sh`) works transparently on both platforms.

---

## Current State Analysis

### What's OpenShift-specific (must be abstracted)

| Layer | OpenShift mechanism | Libvirt equivalent |
|-------|--------------------|--------------------|
| VM creation | KubeVirt VirtualMachine YAML + `oc apply` | `community.libvirt.virt_cloud_instance` (v2.x) or `virt-install` + cloud-init NoCloud ISO |
| VM access | `virtctl port-forward --stdio` + SSH | Direct SSH to VM IP on libvirt network |
| VM scaling | VirtualMachinePool + `oc scale` | Loop: create N VMs via Ansible |
| Networking | Pod network (masquerade) + K8s Service ClusterIP | libvirt NAT network + VM IPs |
| DNS/ingress | OpenShift Route + CNAME | `/etc/hosts` or dnsmasq on libvirt host |
| Storage | PVC + DataVolume clone from DataSource | qcow2 backing file copy |
| Network policy | Kubernetes NetworkPolicy | iptables/nftables on libvirt host |
| Secrets | Kubernetes Secret (cloud-init, RHSM) | cloud-init NoCloud ISO with userdata |

### What's already portable (no changes needed)

- **Cloud-init scripts** (the userdata content) -- works on any hypervisor
- **All Ansible playbooks** (hardening, rpm-whitelist, oscap) -- target the guest OS, not the platform
- **demo-lib.sh** -- purely a presentation framework, zero platform coupling
- **Sections B & C demos** -- only use `run_on_vm()` / `run_on_vm_sudo()` / `upload_to_vm()`

### Existing project conventions to follow

- `ansible-controller/` already has a `provision` role with `libvirt.yml` and `kubevirt.yml` task files, selected by `provisioner` variable
- `community.libvirt.virt` collection is already in use with `vm.xml.j2` template
- `ansible-navigator.yml` configs exist in multiple demos
- `.env` pattern for configuration is established

---

## Architecture Decision

### Platform abstraction in demo-scenarios.sh

Create `scripts/platform-openshift.sh` and `scripts/platform-libvirt.sh`. The main `demo-scenarios.sh` sources the correct one based on `DEMO_PLATFORM` from `.env`. Each platform file implements a fixed set of functions:

```
# Core (required by all demos)
run_on_vm(vm_name, cmd...)
run_on_vm_sudo(vm_name, cmd...)
upload_to_vm(vm_name, dest_path)    # reads stdin
ssh_hint(vm_name, cmd)

# Lifecycle (required by Section A demos)
ensure_vm(vm_name, config_ref)
ensure_pool(pool_name, min_replicas)
vm_exists(vm_name)
delete_vm(vm_name)
wait_vm_ready(vm_name)
list_vms_by_role(role)
get_vm_ip(vm_name)

# Infrastructure (required by deploy.sh and some demos)
get_service_url(service_name)       # returns https://... for UI access
```

### Libvirt provisioning via Ansible

All libvirt VM lifecycle (create, start, stop, delete) is managed by Ansible playbooks under `ansible/`. The demo scripts call `ansible-playbook` (or `ansible-navigator run`) for provisioning operations, and use direct SSH for runtime commands.

### Networking on libvirt

- Create a dedicated libvirt network (`satellite-demo`, e.g. `192.168.150.0/24`) with DHCP + DNS (dnsmasq)
- VMs get static DHCP leases (MAC-to-IP mapping) so IPs are predictable
- IdM and Satellite FQDNs resolve via the libvirt network's dnsmasq or `/etc/hosts` on VMs
- No OpenShift Routes needed -- access Satellite/IdM UIs directly via VM IPs (or SSH tunnel)

---

## Phases

### Phase 0: Design Validation (human review + NotebookLM)

Before implementation, validate RHEL-specific assumptions with NotebookLM using official Red Hat documentation.

**Prompt for NotebookLM** (paste this along with RHEL 9, Satellite 6.18, and IdM/FreeIPA documentation):

```
I'm deploying Red Hat Satellite 6.18, FreeIPA (IdM), and RHEL 9 client VMs on a 
standalone libvirt/KVM host (Fedora 44) instead of OpenShift Virtualization. 
Please validate or correct these assumptions:

1. SATELLITE INSTALLER ON LIBVIRT VM:
   - Can satellite-installer run successfully inside a KVM/libvirt VM with 4 vCPU, 
     20 GiB RAM, 100 GiB root disk + 100 GiB /var/lib/pulp?
   - Are there any known issues with Satellite 6.18 on KVM guests vs bare metal?
   - Does the Satellite installer require the hostname to resolve to a non-loopback 
     IP? What's the correct /etc/hosts configuration?

2. IPA SERVER ON LIBVIRT VM:
   - What are the minimum resource requirements for ipa-server-install on RHEL 9 KVM?
   - The current setup uses `ipaserver_no_reverse: true` and 
     `ipaserver_allow_zone_overlap: true` -- are these still appropriate on a flat 
     libvirt network (no NAT masquerade)?
   - Actually, on libvirt with NAT, the VM sees its real IP (e.g. 192.168.150.10) 
     unlike OpenShift masquerade (10.0.2.2). Does this change the IPA server 
     configuration requirements?

3. CLIENT REGISTRATION:
   - On libvirt NAT, each client VM has a unique IP (unlike OpenShift masquerade 
     where all clients see 10.0.2.2). Does this simplify or change the Kerberos 
     `noaddresses = true` setting?
   - For `ipa-client-install --force-join --force`, is the `--force` flag still 
     needed when the CA cert is already trusted (vs HTTP download)?
   - Does Satellite global registration (`curl https://satellite/register | bash`) 
     work when the client can reach Satellite directly by IP (no K8s Service needed)?

4. SATELLITE REMOTE EXECUTION (REX):
   - In OpenShift masquerade mode, we use pull-mqtt (yggdrasil) because Satellite 
     can't SSH to clients. On libvirt NAT, Satellite CAN reach client IPs. Should 
     we use SSH-based REX instead of pull-mqtt? Or keep pull-mqtt for consistency?
   - If switching to SSH REX: does the Satellite VM need the private SSH key for 
     clients, and how is that configured?

5. NETWORKING:
   - On libvirt NAT network, can VMs in the same network talk to each other 
     directly (VM-to-VM)? 
   - Is there a libvirt equivalent to Kubernetes NetworkPolicy for blocking 
     client-to-client traffic?
   - For Demo A5 (Network Micro-Segmentation), what's the libvirt/nftables 
     equivalent of K8s NetworkPolicy?

6. RHEL 9 CLOUD IMAGE ON LIBVIRT:
   - Can I use the same RHEL 9 KVM guest image (qcow2) from 
     access.redhat.com for both OpenShift DataSource and libvirt VMs?
   - How do I pass cloud-init data to a libvirt VM? Is NoCloud datasource 
     (ISO with meta-data + user-data) the standard approach?
   - Does `virt-install --cloud-init` work with RHEL 9 cloud images or do I 
     need to generate the ISO manually?

7. STORAGE:
   - For Satellite's /var/lib/pulp (100 GiB), should this be a separate qcow2 
     disk attached to the VM, or is a large root disk sufficient?
   - What filesystem is recommended for /var/lib/pulp on KVM? (XFS? ext4?)

8. SUBSCRIPTION MANAGEMENT:
   - VMs on libvirt still need RHSM registration. Can I use the same activation 
     key approach (org + activation key) as on OpenShift?
   - Any differences in repo enablement between KVM guests and OpenShift KubeVirt 
     guests for Satellite 6.18 installation?
```

**What to do with answers**: Any correction that changes the cloud-init scripts, Ansible vars, or networking model should be fed back as constraints before Phase 1 begins.

---

### Phase 1: Implementation -- Platform Abstraction Layer

**Goal**: Refactor demo-scenarios.sh so the existing OpenShift path still works identically, while enabling a second platform driver.

**Subagent 1A: Create platform-openshift.sh** (extract from demo-scenarios.sh)
- Extract `run_on_vm()`, `run_on_vm_sudo()`, `upload_to_vm()`, `ssh_hint()`, `ssh_exec()`, `ensure_vm()`, `ensure_pool()` from `demo-scenarios.sh` into `scripts/platform-openshift.sh`
- Add `vm_exists()`, `delete_vm()`, `wait_vm_ready()`, `list_vms_by_role()`, `get_vm_ip()`, `get_service_url()` wrappers around existing `oc` commands
- These functions already exist inline -- this is a pure extract-and-delegate refactor

**Subagent 1B: Create platform-libvirt.sh** (new implementation)
- Implement the same function interface using direct SSH (no virtctl)
- `run_on_vm()`: SSH directly to VM IP (looked up from a local registry file `~/.cache/satellite-demo/vm-registry.json` or ansible inventory)
- `ensure_vm()`: Call `ansible-playbook ansible/libvirt-vm-create.yml -e vm_name=... -e vm_profile=...`
- `ensure_pool()`: Loop calling `ensure_vm()` for pool-N instances
- `vm_exists()`: Check `virsh list` via SSH to libvirt host, or check local registry
- `get_vm_ip()`: Query `virsh domifaddr` via SSH, or read from DHCP leases
- `get_service_url()`: Return `https://<vm-ip>` (no Route needed)

**Subagent 1C: Update demo-scenarios.sh** (platform dispatch)
- Add to top of file: read `DEMO_PLATFORM` from `.env` (default: `openshift`)
- Source `scripts/platform-${DEMO_PLATFORM}.sh` instead of inline functions
- Remove the extracted functions from demo-scenarios.sh body
- Update `deploy_lc_vm()` and `wait_lc_vm()` to use platform functions

**Subagent 1D: Update .env.sample and deploy.sh**
- Add `DEMO_PLATFORM` variable to `.env.sample` with documentation
- Add libvirt-specific variables:
  ```bash
  # Platform: "openshift" or "libvirt" (default: openshift)
  export DEMO_PLATFORM=openshift
  
  # Libvirt-specific (only when DEMO_PLATFORM=libvirt)
  # export LIBVIRT_HOST=fedora44.example.com        # SSH-accessible libvirt host
  # export LIBVIRT_USER=root                         # SSH user on libvirt host
  # export LIBVIRT_SSH_KEY=~/.ssh/id_ed25519         # SSH key for libvirt host
  # export LIBVIRT_NETWORK=satellite-demo            # libvirt network name
  # export LIBVIRT_POOL_DIR=/var/lib/libvirt/images  # image storage path
  # export LIBVIRT_RHEL9_IMAGE=rhel-9.6-x86_64-kvm.qcow2  # base image filename
  ```
- Create `scripts/deploy-libvirt.sh` -- calls Ansible playbooks instead of `oc apply`
- Update `scripts/deploy.sh` to dispatch: if `DEMO_PLATFORM=libvirt`, call `deploy-libvirt.sh`

**Run 1A and 1B in parallel** (independent). Run 1C after 1A completes (depends on extracted interface). Run 1D in parallel with 1C.

---

### Phase 2: Implementation -- Ansible Provisioning for Libvirt

**Goal**: Full Ansible automation for libvirt VM lifecycle.

**Subagent 2A: Ansible role `libvirt-host-setup`**
- Playbook: `ansible/libvirt-host-setup.yml`
- Tasks:
  - Install libvirt packages on Fedora 44 host (`qemu-kvm-core`, `libvirt`, `virt-install`, `guestfs-tools`, `xorriso`)
  - **IMPORTANT**: Fedora 44 uses modular libvirt daemons. Enable `virtqemud.service` (NOT `libvirtd`), plus support daemon sockets:
    ```
    virtqemud.service, virtnetworkd.socket, virtstoraged.socket,
    virtnodedevd.socket, virtsecretd.socket, virtnwfilterd.socket
    ```
  - Create dedicated libvirt network `satellite-demo` (NAT, `192.168.150.0/24`, DHCP range `.100-.200`, static leases for infra VMs)
  - Create storage pool pointing to `LIBVIRT_POOL_DIR`
  - Set SELinux context for custom pool paths: `virt_image_t`
  - Download/copy RHEL 9 cloud image to pool, resize with `qemu-img resize` to target disk size
  - Configure firewall rules if needed
  - Warn if Docker is installed (Docker iptables rules break libvirt NAT forwarding -- use Podman)
- Variables: all from `.env` libvirt section
- Idempotent: safe to re-run

**Subagent 2B: Ansible role `libvirt-vm` (create/delete VMs)**
- Playbook: `ansible/libvirt-vm-create.yml` / `ansible/libvirt-vm-delete.yml`
- Primary: `community.libvirt.virt_cloud_instance` (new in v2.x -- purpose-built for cloud image + cloud-init workflows, handles image copy, resize, and NoCloud ISO generation in one module call)
- Fallback: `community.libvirt.virt` with manual `genisoimage` for NoCloud ISO (already proven in `ansible-controller/roles/provision/libvirt.yml`)
- Note: `community.libvirt.virt_install` has a known bug with `cloud_init.user_data` (GitHub issue #218) -- avoid it
- VM profiles defined in `ansible/vars/vm-profiles.yml`:
  ```yaml
  vm_profiles:
    idm:
      vcpus: 2
      ram_mb: 4096
      disk_gb: 30
      mac: "52:54:00:de:m0:01"      # static DHCP -> 192.168.150.10
      cloudinit_template: idm
    satellite:
      vcpus: 4
      ram_mb: 22528
      disk_gb: 100
      extra_disks:
        - name: pulp-data
          size_gb: 100
          mount: /var/lib/pulp
      mac: "52:54:00:de:m0:02"      # static DHCP -> 192.168.150.11
      cloudinit_template: satellite
    client:
      vcpus: 1
      ram_mb: 2048
      disk_gb: 30
      cloudinit_template: client     # MAC auto-assigned, DHCP dynamic range
    sec-client:
      vcpus: 1
      ram_mb: 2048
      disk_gb: 30
      cloudinit_template: client
    compliant-client:
      vcpus: 1
      ram_mb: 2048
      disk_gb: 30
      cloudinit_template: client
      base_image: cis-rhel9.qcow2   # override for CIS-hardened image
  ```
- Cloud-init: Generate NoCloud ISO per VM using `genisoimage` (meta-data + user-data)
  - Reuse the same cloud-init userdata content from `k8s/base/*-cloudinit-secret.yaml`
  - Template with Jinja2 (replacing `__IDM_FQDN__`, etc.)
  - Key difference from OpenShift: `/etc/hosts` maps FQDN to real VM IP (not 10.0.2.2)
- VM XML template: Extend existing `vm.xml.j2` with cloud-init disk and extra disks
- Post-create: Register VM IP in local state file for `platform-libvirt.sh` to find

**Subagent 2C: Ansible playbook `deploy-all.yml` (full stack orchestration)**
- Playbook: `ansible/deploy-all.yml`
- Sequence:
  1. Run `libvirt-host-setup`
  2. Create IdM VM, wait for cloud-init completion (poll SSH for setup log)
  3. Create Satellite VM (parallel with IdM wait), wait for installation
  4. Optionally upload manifest
  5. Create client cloud-init template (ready for on-demand client creation)
- This replaces `scripts/deploy.sh` for the libvirt platform

**Subagent 2D: Custom Execution Environment**
- Create `ansible/execution-environment.yml` for `ansible-builder` (v3 schema):
  ```yaml
  version: 3
  images:
    base_image:
      name: registry.redhat.io/ansible-automation-platform-26/ee-minimal-rhel9:latest
  dependencies:
    galaxy:
      collections:
        - name: community.libvirt
    python:
      - libvirt-python
      - lxml
    system:
      - gcc [compile platform:rpm]
      - pkg-config [compile platform:rpm]
      - python3-devel [compile platform:rpm]
      - libvirt-devel [platform:rpm]
      - libvirt-client [platform:rpm]
      - virt-install [platform:rpm]
      - openssh-clients [platform:rpm]
      - sshpass [platform:rpm]
      - xorriso [platform:rpm]
  options:
    package_manager_path: /usr/bin/dnf
  ```
  Note: `libvirt-python` on PyPI is source-only, hence `gcc`, `pkg-config`, `python3-devel`, `libvirt-devel` are needed as compile-time dependencies.
- Create `ansible/ansible-navigator.yml` for this demo, with SSH agent socket mount and optional libvirt socket mount for local hypervisor use
- Create `ansible/requirements.yml` for galaxy collections
- Document build command: `ansible-builder build -t satellite-demo-ee`

**Run 2A, 2B, 2C, and 2D all in parallel** (independent files). 2C references roles from 2A/2B but can be written in parallel since the interface (role names, variable names) is defined above.

---

### Phase 3: Implementation -- Demo Adaptations

**Goal**: Make Section A demos (platform-specific) work on libvirt. Sections B & C should work with no changes (they only use `run_on_vm` which is already abstracted).

**Subagent 3A: Adapt Section A demos for libvirt**
- `demo_a1` (Zero-Touch Provisioning): Replace `oc apply -f client-vm.yaml` with `ansible-playbook ansible/libvirt-vm-create.yml -e vm_name=client -e vm_profile=client`
- `demo_a2` (Elastic Scaling): Replace `oc scale vmpool` with loop creating N client VMs
- `demo_a3` (Self-Healing): On libvirt, self-healing means `virsh destroy` + `virsh start` (or configure libvirt `on_crash=restart`). Different narrative than K8s but same concept.
- `demo_a4` (IP-Agnostic Kerberos): On libvirt each VM has a unique IP, so the "duplicate IP" scenario doesn't apply. Adapt demo to show Kerberos works across the libvirt network instead.
- `demo_a5` (Network Micro-Segmentation): Replace K8s NetworkPolicy with nftables rules on the libvirt host. Create `ansible/libvirt-network-policy.yml` to apply/verify rules.

**Subagent 3B: Adapt deploy.sh dispatcher**
- Update `scripts/deploy.sh` to check `DEMO_PLATFORM`:
  - `openshift`: existing flow (unchanged)
  - `libvirt`: call `ansible-navigator run ansible/deploy-all.yml` with appropriate env vars passed as `--extra-vars`
- Update `scripts/verify-registration.sh` similarly
- Update `scripts/reset-clients.sh` for libvirt (delete client VMs via Ansible)

**Run 3A and 3B in parallel.**

---

### Phase 4: Testing -- Deploy to Real Server

**Goal**: Deploy the full stack on a real Fedora 44 libvirt host, validate each demo, fix issues iteratively.

**Prerequisites** (human):
- Fedora 44 server accessible via SSH with KVM support
- RHEL 9 cloud qcow2 image downloaded from access.redhat.com
- RHSM activation key with Satellite + RHEL subscriptions
- Satellite manifest ZIP

**Test sequence** (each step validates before proceeding):

```
Step 1: Host setup
  ansible-navigator run ansible/libvirt-host-setup.yml
  Validate: virsh net-list shows satellite-demo network, pool has RHEL image

Step 2: IdM deployment
  ansible-navigator run ansible/deploy-all.yml --tags idm
  Validate: ipa-client-install works, kinit admin succeeds, 
            web UI accessible at https://<idm-ip>

Step 3: Satellite deployment
  ansible-navigator run ansible/deploy-all.yml --tags satellite
  Validate: hammer ping succeeds, web UI accessible at https://<sat-ip>,
            manifest uploaded, repos synced

Step 4: Client deployment
  ./scripts/demo-scenarios.sh a1    (with DEMO_PLATFORM=libvirt in .env)
  Validate: client appears in `hammer host list` and `ipa host-find`

Step 5: Section A demos
  ./scripts/demo-scenarios.sh a     (run all)
  Fix any platform-specific issues

Step 6: Section B demos  
  ./scripts/demo-scenarios.sh b     (run all)
  These should work without changes since they only use run_on_vm

Step 7: Section C demos
  ./scripts/demo-scenarios.sh c     (run all)
  Same -- lifecycle demos are Satellite-side, platform-agnostic

Step 8: Full reset and redeploy
  Clean teardown + redeploy from scratch to validate idempotency
```

**Iterate**: After each failed step, fix the issue, re-run. Continue until all demos pass on libvirt.

---

### Phase 5: Documentation

**Goal**: Document the final system architecture.

Create `docs/ARCHITECTURE-multiplatform.md` with:

1. **System overview diagram** (ASCII): showing both platform paths
2. **Platform abstraction layer**: which functions each platform implements
3. **Directory structure**: new files and their purpose
4. **Configuration reference**: all `.env` variables for each platform
5. **Ansible role reference**: each role/playbook, its purpose, key variables
6. **Execution Environment**: how to build and use the custom EE
7. **Networking differences**: OpenShift masquerade vs libvirt NAT -- what changes
8. **Demo compatibility matrix**: which demos work on which platform and any behavioral differences
9. **Troubleshooting**: common issues per platform

---

## File Tree (new/modified files)

```
demo-satellite-cloud-native/
  .env.sample                          # MODIFIED: add DEMO_PLATFORM + libvirt vars
  scripts/
    deploy.sh                          # MODIFIED: dispatch to deploy-libvirt.sh
    deploy-libvirt.sh                  # NEW: calls ansible for libvirt deployment
    demo-scenarios.sh                  # MODIFIED: source platform-*.sh, remove inline functions
    demo-lib.sh                        # UNCHANGED
    platform-openshift.sh              # NEW: extracted OpenShift functions
    platform-libvirt.sh                # NEW: libvirt SSH + ansible functions
    verify-registration.sh             # MODIFIED: platform-aware
    reset-clients.sh                   # MODIFIED: platform-aware
  ansible/
    ansible-navigator.yml              # NEW: navigator config for this demo
    execution-environment.yml          # NEW: EE build definition
    requirements.yml                   # NEW: galaxy collection requirements
    deploy-all.yml                     # NEW: full stack orchestration playbook
    libvirt-host-setup.yml             # NEW: prepare libvirt host
    libvirt-vm-create.yml              # NEW: create single VM
    libvirt-vm-delete.yml              # NEW: delete single VM
    libvirt-network-policy.yml         # NEW: nftables rules for demo a5
    vars/
      vm-profiles.yml                  # NEW: VM resource/network definitions
    templates/
      vm.xml.j2                        # NEW: libvirt domain XML (extended from ansible-controller)
      cloud-init/
        meta-data.j2                   # NEW: cloud-init meta-data template
        idm-userdata.j2                # NEW: extracted from k8s/base/idm-cloudinit-secret.yaml
        satellite-userdata.j2          # NEW: extracted from k8s/base/satellite-cloudinit-secret.yaml
        client-userdata.j2             # NEW: extracted from k8s/base/client-cloudinit-secret.yaml
    inventory/
      libvirt-host.yml                 # NEW: inventory for the libvirt host
  docs/
    ARCHITECTURE-multiplatform.md      # NEW: system architecture documentation
```

---

## Execution Instructions for Claude

When executing this plan in a fresh context, use the following approach:

### Setup
```
Read these files first to understand the project:
- CLAUDE.md (project context)
- PLAN-libvirt-platform.md (this plan)
- scripts/demo-scenarios.sh (main demo script)
- scripts/demo-lib.sh (demo framework)
- scripts/deploy.sh (deployment script)
- .env.sample (configuration)
- ansible-controller/roles/provision/tasks/libvirt.yml (existing libvirt pattern)
- ansible-controller/roles/provision/templates/vm.xml.j2 (existing VM template)
```

### Phase 1 execution (use subagents)
```
Launch 2 subagents in parallel:
  Agent 1A: Extract platform functions from demo-scenarios.sh into scripts/platform-openshift.sh
  Agent 1B: Create scripts/platform-libvirt.sh with the same interface using direct SSH

Then sequentially:
  Agent 1C: Update demo-scenarios.sh to source platform-${DEMO_PLATFORM}.sh
  Agent 1D: Update .env.sample and create deploy-libvirt.sh (parallel with 1C)
```

### Phase 2 execution (use subagents)
```
Launch 4 subagents in parallel:
  Agent 2A: Create ansible/libvirt-host-setup.yml
  Agent 2B: Create ansible/libvirt-vm-create.yml + vars/vm-profiles.yml + templates/
  Agent 2C: Create ansible/deploy-all.yml
  Agent 2D: Create ansible/execution-environment.yml + ansible-navigator.yml + requirements.yml
```

### Phase 3 execution (use subagents)
```
Launch 2 subagents in parallel:
  Agent 3A: Adapt Section A demos in demo-scenarios.sh for libvirt platform
  Agent 3B: Update deploy.sh, verify-registration.sh, reset-clients.sh for platform dispatch
```

### Phase 4: Testing (interactive with human)
```
Human deploys to real Fedora 44 server.
Claude assists with debugging and fixing issues iteratively.
Follow the test sequence in Phase 4 above.
```

### Phase 5: Documentation
```
Single agent: Create docs/ARCHITECTURE-multiplatform.md based on the final implemented system.
```

---

## Key Technical Details from Research

### community.libvirt v2.x (2026)

| Module | Use case |
|--------|----------|
| `virt_cloud_instance` | **Primary choice** -- handles image download/copy, resize, cloud-init ISO, VM define+start in one call |
| `virt` | Low-level define/start/stop/destroy from XML. Proven in existing `ansible-controller/`. Fallback. |
| `virt_net` | Create/manage libvirt networks |
| `virt_pool` | Create/manage storage pools |
| `virt_volume` | Manage volumes; has `create_cidata_cdrom` command for cloud-init ISOs |
| `virt_install` | Declarative wrapper around `virt-install`. **Avoid**: `cloud_init.user_data` bug (issue #218) |

All modules support remote URIs: `qemu+ssh://root@hypervisor/system`

### Cloud-init conversion: KubeVirt to libvirt

KubeVirt's `cloudInitNoCloud` in a Secret is the same NoCloud format that libvirt uses. The userdata content is identical. Key differences:
- **meta-data**: KubeVirt auto-generates it; for libvirt, create manually with `instance-id` and `local-hostname`
- **NoCloud ISO**: Generate with `genisoimage -output cidata.iso -volid cidata -joliet -rock user-data meta-data` (volume label **must** be `cidata`)
- **network-config**: Use Version 1 format for RHEL 9 (not netplan V2)
- **/etc/hosts**: On OpenShift masquerade, VMs map FQDN to `10.0.2.2`. On libvirt NAT, map to real VM IP (e.g. `192.168.150.10`)

### Fedora 44 libvirt host specifics

- **Modular daemons** (mandatory): `virtqemud.service` + companion sockets, NOT `libvirtd`
- **Docker conflict**: Docker's iptables DENY rules break libvirt NAT forwarding -- use Podman
- **SELinux**: Keep enforcing. Default path `/var/lib/libvirt/images/` has correct `virt_image_t` label. Custom paths need `semanage fcontext`.
- **RHEL 9 cloud image**: Resize with `qemu-img resize rhel9-kvm.qcow2 50G` before first boot; cloud-init auto-grows the partition

### Reference projects

| Project | Relevance |
|---------|-----------|
| `redhat-cop/rhis-builder` | Closest match: deploys IdM + Satellite + AAP lab (VMware/AWS, not libvirt yet) |
| `redhat-cop/agnosticd` | Multi-cloud deployer, has `configs/satellite-vm/`. Gold standard for provider abstraction |
| `stackhpc/ansible-role-libvirt-vm` | Variable-driven VM creation with cloud image support |
| `theforeman/forklift` | Vagrant+Ansible for Foreman/Katello dev, supports `vagrant-libvirt` |

---

## Risk Mitigations

| Risk | Mitigation |
|------|-----------|
| Cloud-init differences between KubeVirt and libvirt | Extract userdata content, template platform-specific parts (e.g., /etc/hosts IP mapping) |
| Satellite installer fails on libvirt VM | Validate resources with NotebookLM (Phase 0), test early in Phase 4 |
| Libvirt network doesn't allow VM-to-VM traffic | Use `routed` or `nat` mode with proper forwarding; test in Phase 4 Step 1 |
| Section A demos have no libvirt equivalent | Accept behavioral differences (document in compatibility matrix), adapt narrative |
| SSH connectivity assumptions differ | OpenShift uses virtctl proxy (localhost), libvirt uses real IPs; platform-libvirt.sh handles this |
| ansible-navigator EE missing libvirt-python | EE definition includes it explicitly; test build in Phase 4 |
