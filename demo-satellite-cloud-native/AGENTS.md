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
| **Local SOE** | libvirt on this machine | `scripts/deploy-soe.sh` + `.env.soe` | satellite, lc-dev, lc-qa, lc-prod, centos |

The local profile is the remote libvirt path with `LIBVIRT_HOST=localhost`: the deploy still goes over SSH, it just loops back, so `qemu+ssh://`, scp and the `ProxyCommand` hop to VMs are all unchanged. Switches: `DEMO_LOCAL_PROFILE=true`, `DEPLOY_IDM=false`, `DEPLOY_CAPSULE=true`. Deploy phases are strictly serial (Satellite -> Capsule base -> Capsule join); overlapping them would need 18 GB of concurrent guest RAM.

**The Capsule and CentOS client are libvirt-only by design** — `k8s/base/` deliberately has no manifests for them, and demo Section D refuses to run unless `DEMO_PLATFORM=libvirt`.

The **SOE profile** is a variant of the local profile for a 25-minute Standard Operating Environment talk: the Capsule is off (`DEPLOY_CAPSULE=false`) and its 6 GB pays for `lc-dev`/`lc-qa`/`lc-prod`, while the CentOS client moves from behind the Capsule to straight off the Satellite (`DEPLOY_CENTOS=true`). Guests are trimmed via `LC_VM_PROFILE=lc-client-soe` and `CENTOS_VM_PROFILE=centos-client-soe` (1536 MB each), so the whole stack is 12288 + 4×1536 = 18 GB — inside the local profile's 20 GB envelope. Entry points: `scripts/deploy-soe.sh` (phased, `--check` / `--infra-only` / `--clients-only`), `scripts/teardown-soe.sh` (`--orphans` / `--all` / `--dry-run`), run sheet in `RUNSHEET-soe.md`.

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
- **The VM registry is consulted before `virsh`.** `_libvirt_get_vm_ip` reads `~/.cache/satellite-demo/vm-registry.json` first, so a stale entry for a deleted VM hands out a dead DHCP address and every `run_on_vm` silently targets nothing. `teardown-soe.sh` prunes entries whose VM is no longer defined; any new teardown path must do the same.
- **The host's `/etc/hosts` block was gated on `capsule_fqdn` as well as `sat_fqdn`.** Any profile without a Capsule therefore got *no* entry at all and the browser could not resolve the Satellite — the one thing that block exists for. It is now gated on `sat_fqdn` alone, with the Capsule line conditional.
- **Phase 5 of `deploy-all.yml` mkdir'd the client-template directory over SSH without sudo.** `LIBVIRT_POOL_DIR` is root-owned, so this only worked when `LIBVIRT_USER=root` (the remote profile) and failed with "Permission denied" on both local profiles, after the Satellite had already finished installing. The directory is now created with sudo and the templates are staged through `/tmp`.
- **Section C's `RHEL9-Lifecycle` attached repositories by hardcoded id 1 and 2.** Those ids only exist after a subscription manifest is uploaded and the RHEL repos enabled; with no manifest both adds failed behind `|| true` and the content view published empty with no indication why. It now looks the repos up by name and prints an explicit note when none are present.

## Running Section C on libvirt

Section C was written for OpenShift and `PLAN-libvirt-platform.md` called it platform-agnostic, but it had not been run on libvirt. Three things were actually platform-specific and are now fixed: the hardcoded repository ids above, a bare `oc get route` in `demo_c1`'s summary (printed a command-not-found error mid-demo on libvirt), and `deploy_lc_vm` hardcoding `vm_profile=lc-client` (now honours `LC_VM_PROFILE`).

**Without a subscription manifest the lifecycle demo runs entirely on the custom `Demo-App` product.** That is enough for the promotion story — content view, version, environment, activation key are the same mechanism — but it means no RHEL errata are being promoted, and the run sheet says so out loud rather than letting a presenter imply otherwise.

## Section E: non-RHEL in the SOE

`e1` registers the CentOS Stream client straight to the Satellite (no Capsule) and installs a custom RPM; `e2` proves the remote-execution limit instead of asserting it. The distinction from Section D matters: D registers CentOS with `--setup-remote-execution-pull false`, which *configures the limit away*. E registers with it set to `true`, exactly as a RHEL host does, and then shows that `foreman_ygg_worker` is unavailable because `satellite-client-6` has no CentOS Stream build — so the same job template runs on `lc-prod` and has no transport to `centos`.

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
- `scripts/deploy-soe.sh` - SOE profile: pre-flight, Satellite, then builds Section C1 + E1 state in batch mode
- `scripts/teardown-soe.sh` - Returns the workstation to its prior state (`--orphans`, `--all`, `--dry-run`)
- `RUNSHEET-soe.md` - 25-minute run sheet for the SOE talk: timings, UI vs CLI, what to say, recovery
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
- `gitops/` - GitOps layer for the OpenShift profile: servers created by hand (V1), by Git PR (V2) or by an AAP survey that opens the PR (V3); Satellite structure and content promotion/rollback from `releases.yml`, applied by an Argo CD PostSync Job. Env file `.env.ocp` (gitignored). See `gitops/README.md`.

## GitOps Layer Notes (`gitops/`)

- **Requires demo c1 first.** `structure.yml` mirrors c1's names (`Demo_Org`, location `Cloud`, Dev/QA/Prod, `RHEL9-FullStack`, `rhel9-lc-*`) and `releases.yml` promotes `RHEL9-FullStack` versions that c1/`publish-version.sh` created.
- **Do not run c2 while the GitOps layer is active.** c2 promotes to Dev directly; the next `satellite-config` sync moves Dev back to what Git declares. Use `gitops/scripts/publish-version.sh` (publish only) + `release.sh promote`.
- **Nothing secret goes into the Gitea repo.** `fleet-cloudinit-<env>`, `satellite-cac-credentials` and `satellite-registration` are created in the cluster by `bootstrap.sh` / the Job.
- **Playbooks use `theforeman.foreman`** (Galaxy, no token) so the in-cluster runner builds without Automation Hub credentials; `redhat.satellite` is a prefix swap.
- **AAP runs on the same cluster** (`bootstrap.sh aap`): AAP 2.7 operator, channel `stable-2.7`, namespace `aap`, instance `aap` with only gateway + controller (hub, EDA disabled to save capacity next to the Satellite VM). It does not depend on the Satellite, so start it in parallel with `deploy.sh`. The admin password comes from Secret `aap-admin-password`; the subscription is activated from `AAP_MANIFEST` if set, otherwise by hand in the UI. `aapconfig` applies `repo/aap/aap-config.yml` with the laptop's `infra.aap_configuration`, and points the project and the Gitea credential at the **internal** Gitea service URL because AAP job pods run in the cluster. Unverified against a live cluster: gateway route name, the `/api/controller/v2/config/` manifest upload, and whether a manifest already loaded in Satellite is accepted by AAP too.
- **The runner sets `ANSIBLE_REMOTE_TMP`/`ANSIBLE_LOCAL_TEMP` to /tmp.** OpenShift's random UID has no passwd entry, and without it Ansible tries to create its temp dir in the read-only ConfigMap mount.

## GitOps Gotchas (found on a live OCP 4.21 cluster)

- **OpenShift GitOps is often already installed** (lab and shared clusters ship it in `openshift-operators`). A second Subscription for the same package in `openshift-gitops-operator` makes OLM conflict and can upgrade an Argo CD instance other workloads share. `bootstrap.sh operator` reuses any existing `openshift-gitops-operator` Subscription; only additive changes go to the shared `openshift-gitops` instance.
- **Argo CD reconciliation is `spec.controller.appSync`, not `extraConfig.timeout.reconciliation`.** The operator renders `ARGOCD_RECONCILIATION_TIMEOUT` from `appSync`; the extraConfig key is silently ignored.
- **The Argo CD webhook matches the payload's `repository.html_url` host against each app's `repoURL`.** Gitea's `html_url` is its ROOT_URL (the route host), so applications pointing at the in-cluster service URL ignore every webhook and wait for polling. The apps use the Gitea route URL (plus a repository Secret with `insecure: "true"` for self-signed routers); AAP job pods still use the internal service URL.
- **The AAP operator CSV is named `aap-operator.v2.x-…`**, not after the package. Wait on the Subscription's `.status.installedCSV`.
- **The AAP gateway answers `/api/gateway/v1/ping/` minutes before the controller exists behind it**; every `/api/controller/` call meanwhile returns `503 no healthy upstream`. Wait for `/api/controller/v2/ping/` too before the license upload or `aapconfig`.
- **`upload-manifest.sh` used to detect "RHEL repos available" with `repository-set list --per-page 1 | grep "Red Hat"`.** The first set alphabetically is "Advanced Virtualization Beta ...", so a perfectly good manifest was reported as "no Red Hat repository sets found" and BaseOS/AppStream were never enabled. It now asks for the BaseOS repository set by name. Re-uploading the same manifest is harmless (`MANIFEST_SAME`).
- **AAP accepts the Satellite subscription manifest** (an allocation with an AAP-capable SKU) through `POST /api/controller/v2/config/`; no separate allocation or UI step was needed.
- **AAP 2.7 has no controller token endpoint** (`/api/controller/v2/tokens/` is 404). `ansible.controller` modules given username/password try to fetch a token there and fail with "Failed to get token: 404". `bootstrap.sh aapconfig` creates a short-lived gateway token (`/api/gateway/v1/tokens/`), passes it as `aap_token`, and deletes it afterwards. `aapconfig` also needs a seeded Gitea repo (the project update fails on an empty repo with "pathspec 'main'").
- **Timings on a nested-virt OCP 4.21 lab cluster:** Satellite VM install 62 min (four installer runs of ~20 min: base, REX pull, OpenSCAP, package install), BaseOS + AppStream sync with `on_demand` 45 min, AAP operator + gateway + controller ~20 min, Gitea + runner build + Argo CD wiring ~3 min.
- **Errata date filters cannot include "packages without errata".** Katello rejects `--original-packages` on erratum filters (`not supported for Katello::ContentViewErratumFilter`). An errata inclusion filter therefore needs a second rpm inclusion filter with `--original-packages true`, or the content view loses every package that belongs to no erratum. In hammer 6.19 the date/type filter is `--type erratum_date`.
- **The cloud image date is `rpm -q --qf '%{INSTALLTIME}' basesystem`, not the newest BUILDTIME** (that is demo-app, built on the Satellite today).
- **Never incrementally update or publish the RHEL content view live.** On a nested-virt lab Satellite, publishing `RHEL9-Lifecycle` (BaseOS + AppStream, errata filter) took 40 min, and an incremental update of one RHSA into it ran as long (it regenerates BaseOS/AppStream metadata for the component and every composite that uses it). The live incremental update therefore targets the tiny Demo-App-CV (`gitops/scripts/hotfix.sh`), and real RHSAs are shown in the UI only. Composite publishes are fast (~30 s) because they reuse component publications.
- **Incremental update of a component that only lives in Library:** pass `--lifecycle-environments Library --propagate-all-composites true`. Naming the composite's environment (`Prod`) fails with "Content View Version N not in all specified environments".
- **Errata for custom content need a sync, not an upload.** `prepare-hotfix.sh` serves a small repo with `updateinfo.xml` from the Satellite's `/pub` and gives the upload-based `demo-app-rpms` that URL with `--mirroring-policy additive`, so uploaded packages stay. `createrepo_c` on the Satellite is only installable by bypassing foreman-protector, so the repodata is generated in a local Fedora container instead.
- **demo-app ships a web page** (`Requires: httpd`, `/var/www/html/index.html` with version and host, auto-refresh 10 s); `deploy_lc_vm` adds Service + Route `lc-<env>-web`. The page text passes through `bash -c '...'` and an unquoted heredoc on the Satellite: install-time expressions need `\\\$` in the source.
- **The Job must call the Satellite API on `SAT_FQDN`, not the service name.** Satellite builds the registration command from the URL the API was called with; a command pointing at `satellite.<ns>.svc.cluster.local` fails on the host ("no alternative certificate subject name matches") after the host record is created, so the host shows up without host group. `SATELLITE_API_URL` defaults to `https://$SAT_FQDN` (reached through the passthrough route). A VM bakes the `satreg` Secret in at start: after changing it, recreate the VMs.
- **A fleet VM takes 7-8 min from creation to "registered"** (cloud-init final stage ~7 min: CDN registration + packages, IdM, Satellite). Argo CD syncs ~3 s after a merge (webhook) and self-heals a deleted VM in ~12 s; the satellite-cac Job takes ~95-120 s.
- **AAP 2.7 UI automation:** survey fields are PatternFly menu toggles with `data-cy="survey-<variable>-form-group"` (variable name with `_` -> `-`), not `<select>`s; the login form renders after `load`, so wait for the Username field.
- **Never merge a `satellite/` PR while a satellite-cac Job is running.** Argo CD skips the auto-sync ("Skipping auto-sync: another operation is in progress", later "most recent sync already to <rev>"), no Job runs for that commit and the app stays OutOfSync; Refresh does not help, a manual **Sync** does. Do not "fix" this with `selfHeal: true`: self-heal syncs as a partial sync, which skips hooks, so the ConfigMap changes, no Job runs and the app shows Synced (tested). `release.sh` warns when a sync is running and `--merge` waits for it.
- **Versions keep counting after a reset.** reset.sh moves environments back to the baseline but leaves newer versions published (6.0, 5.1, ...), so the next publish and the next hotfix get higher numbers (7.0, 5.2). Scripts print the real numbers; the run sheet uses them as examples only.
- **An empty Argo CD UI is RBAC, not missing apps.** The default `openshift-gitops` instance grants `role:admin` only to the groups `system:cluster-admins` and `cluster-admins` (`defaultPolicy: ""`). An htpasswd `admin` user on a lab cluster is in no OpenShift group, so after "Log in via OpenShift" it sees nothing. Fix (cluster-scoped, done by the cluster owner): `oc adm groups new cluster-admins <user>`, then log out and in again (groups are read at login).
- **Leftover PR branches break the next request.** Branches merged in the Gitea UI stay behind; a second request for the same server name then fails with 422 "branch already exists". The V3 playbook deletes a leftover `add-<name>` branch when the file is not on main, and `reset.sh` deletes every branch except main.
- **`uri` prints request headers in the job output.** An `Authorization: token ...` header ends up in clear text in AAP. Pass API tokens as `url_password` with `force_basic_auth: true` (Gitea accepts the token as the basic-auth password); `url_password` is censored.
- **Never edit a script while a background run of it is still going.** Bash reads scripts incrementally, so the running copy continues from a byte offset in the new file (seen as `line 397: s: command not found`).
- **An unlicensed AAP controller reports `license_type: "UNLICENSED"`** in `/api/controller/v2/config/`. Test `license_info.valid_key is True`, never "license_type is set".
- **ansible-navigator needs `ansible-runner` inside the EE.** Without it every run fails with an `awx_display` callback error. Do not bind-mount host files with `:Z` (it relabels the originals); copy them into a temp dir first. Rootless podman's UID 1001 cannot read a 0600 kubeconfig.
- **A VM secret volume whose Secret is missing blocks the boot** (virt-launcher cannot mount it), so a cloud-init fallback never runs. Mark optional volumes `optional: true` and create an empty placeholder Secret.
- **UI promotions must not be reverted by an unrelated sync.** The Job only acts on environments whose `releases.yml` value changed since its last run (ConfigMap `satellite-cac-applied`); anything else that differs is reported as DRIFT until `release.sh record` writes it into Git. `drift: enforce` restores strict GitOps. `reset.sh` deletes the ConfigMap so the next run enforces everything.
- **Versions in `releases.yml` must be quoted strings `"x.y"`.** YAML reads unquoted `3.10` as the float 3.1; `| string` would hide it. The Job asserts the type and pattern.
- **Gitea answers 405 to a merge right after the PR was created** (mergeability check still running). Merge calls retry; `gitea_pr` reuses an open PR for the branch so the documented "--merge after opening it in the UI" recovery works.
- **`content_view_version` publishes a new version when the declared one does not exist.** The "declared versions exist" assert must stay in front of the promote task.

## Kustomize Layout

```
k8s/base/           # namespace, IdM (vm + cloudinit + svc), Satellite (vm + cloudinit + svc + route + pvc),
                     # client (vm + cloudinit + pool), compliant-client-vm, network-policy
k8s/overlays/demo/   # Adds environment: demo label
```

## Key Commands

```bash
# SOE profile (Satellite + lc-dev/lc-qa/lc-prod + CentOS client, no Capsule, no IdM)
cp .env.soe.sample .env.soe && $EDITOR .env.soe
./scripts/deploy-soe.sh --check       # pre-flight only, changes nothing
./scripts/deploy-soe.sh               # ~2 - 3.5 h (Satellite 70-150 min of it)
./scripts/deploy-soe.sh --infra-only  # stop after the Satellite
./scripts/deploy-soe.sh --clients-only  # just the 4 clients, Satellite must exist

source .env.soe
./scripts/demo-scenarios.sh c2        # the promotion act
./scripts/demo-scenarios.sh e2        # the non-RHEL REX limit

./scripts/teardown-soe.sh --all --dry-run   # see the full undo first
```

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

# Section E: Non-RHEL in the SOE (VMs: centos, lc-prod) — local libvirt profile only
./scripts/demo-scenarios.sh e1   # CentOS registers to the Satellite, installs an SOE RPM
./scripts/demo-scenarios.sh e2   # Same REX job: runs on RHEL, undeliverable to CentOS
./scripts/demo-scenarios.sh e    # Run all Non-RHEL demos

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
