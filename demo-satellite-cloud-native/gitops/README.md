# GitOps layer: servers and Satellite configuration from Git

Adds a GitOps workflow on top of the **OpenShift profile** of this demo
(`DEMO_PLATFORM=openshift`, `scripts/deploy.sh`). One Git repository holds
the RHEL fleet *and* the Satellite configuration; Argo CD applies it.

It shows three ways to create a server side by side, and content lifecycle
(promotion, rollback) driven by pull requests.

| | How a server is created | Control | Effort for the requester |
|---|---|---|---|
| **V1 legacy** | Admin creates the VM by hand, it auto-registers to Satellite | None: no review, no record of who asked | Needs cluster access and know-how |
| **V2 Git PR** | A pull request adds `fleet/<env>/<name>.yaml`; merge = server | Maximum: review, history, revert | Needs Git and YAML |
| **V3 AAP self-service** | AAP survey opens the PR for you, optional auto-merge | Same as V2, approval optional | A form |

All three use the same VM template, cloud-init and Satellite registration;
only the *path* differs.

## Architecture

```
                         Gitea (in cluster)  repo gitops/rhel-fleet
           ┌────────────────────┬─────────────────────┬──────────────────┐
           │ fleet/<env>/*.yaml │ satellite/          │ aap/             │
           │ (one VM per file)  │ releases.yml        │ create-server-   │
           │                    │ structure.yml       │ pr.yml (V3)      │
           └─────────┬──────────┴──────────┬──────────┴────────▲─────────┘
                     │ push webhook        │                   │ PR via API
        ┌────────────▼──────────┐ ┌────────▼─────────────┐  ┌──┴──────────────┐
        │ Argo CD app           │ │ Argo CD app          │  │ AAP job template│
        │ rhel-fleet            │ │ satellite-config     │  │ "Request RHEL   │
        │ auto-sync/prune/heal  │ │ ConfigMap + PostSync │  │  server" survey │
        └────────────┬──────────┘ │ Job (ansible)        │  └─────────────────┘
                     │            └────────┬─────────────┘
                     ▼                     │ theforeman.foreman / redhat.satellite
   VirtualMachine on OpenShift Virt        ▼
     cloud-init: fleet-cloudinit-<env>   Satellite: lifecycle envs, CVs, keys,
     disk satreg: registration command ◀─ host groups, patch waves, RBAC,
     (activation key + host group)        promotion per releases.yml,
                     │                    Secret satellite-registration
                     └──── registers ───▶ Satellite (Dev / QA / Prod)

   V1: oc apply / console ──▶ same VirtualMachine, not in Git (Argo CD ignores it)
```

What lives where:

| In Git (Gitea) | Only in the cluster |
|---|---|
| VM manifests, `releases.yml`, `structure.yml`, VM template, AAP playbook | `fleet-cloudinit-<env>` (demo password), `satellite-cac-credentials`, `satellite-registration` (registration JWTs), `rhsm-credentials` |

Production path for the cluster-only secrets: External Secrets Operator
(Vault, cloud secret manager) or Sealed Secrets, so they can be versioned too.

## Directory layout

```
gitops/
  bootstrap/               cluster-side setup, applied by bootstrap.sh (not synced by Argo CD)
    gitops-operator.yaml   OpenShift GitOps Subscription
    gitea.yaml             Gitea (Deployment, PVC, Service, Route)
    argocd-rbac.yaml       Argo CD may manage the demo namespace
    applications.yaml      Argo CD apps rhel-fleet + satellite-config
    fleet-cloudinit-secret.yaml.tpl  per-env cloud-init (rendered from the env file)
  runner/Containerfile     ansible-core + theforeman.foreman image for the Job
  repo/                    seeded into Gitea as gitops/rhel-fleet
    fleet/                 one VirtualMachine per file
    templates/vm.yaml.j2   the VM template (V1, V2, V3)
    satellite/             site.yml, structure.yml, releases.yml, tasks/, Job + RBAC, kustomization
    aap/                   V3 playbook + AAP config as code (infra.aap_configuration)
  scripts/
    bootstrap.sh           bring-up, phase by phase, idempotent
    manual-vm.sh           V1
    new-server.sh          V2 (branch + PR link, or --open-pr / --merge)
    release.sh             promote dev|qa|prod [VERSION] / record / rollback, as a PR
    publish-version.sh     build demo-app RPM + publish CVs (no promotion)
    hotfix.sh              incremental update: one erratum into the version an environment serves
    prepare-errata.sh      one-time: errata date filter on RHEL9-Lifecycle (real RHSAs become "applicable")
    prepare-hotfix.sh      one-time: demo-app security erratum (repo with updateinfo, exclude filter)
    reset.sh               back to the start state (Git, fleet VMs + hosts, patch waves, lc-* packages)
    status.sh              Git vs Satellite vs hosts vs Argo CD, with a drift line
    run-local.sh           fallback: run the Satellite playbook from the laptop
```

## Prerequisites

- OpenShift 4.14+ with OpenShift Virtualization, DataSource `rhel9`, RWO storage, internal image registry.
- The base demo deployed with the OpenShift profile: `scripts/deploy.sh` (IdM, Satellite), manifest uploaded (optional), and **demo c1 run** (`scripts/demo-scenarios.sh c1`): it creates Dev/QA/Prod, `RHEL9-FullStack`, the `rhel9-lc-*` keys, the `/pub/register-lc-*.sh` fallback scripts and lc-dev/qa/prod.
- Laptop: `oc`, `virtctl`, `sshpass`, `git`, `curl`, `ansible` (template rendering), `python3`. For `run-local.sh`: `ansible-navigator`, `podman`.
- V3: AAP runs **on the same cluster** (`bootstrap.sh aap`, AAP 2.7 operator, gateway + controller only). `aapconfig` needs `infra.aap_configuration`, `ansible.platform` and `ansible.controller` on the laptop. To use an existing AAP instead, run `repo/aap/configure-aap.yml` against it by hand and set `AAP_ENABLED=false`.
- Capacity: Satellite 4 vCPU / 22 GiB, IdM 2 / 4, four clients 1 / 2 each, AAP (gateway, controller, PostgreSQL, Redis) roughly 4 vCPU / 8-10 GiB in requests, plus OpenShift GitOps and Gitea. Check `oc adm top nodes` before the bring-up.

### Env file

The scripts read `DEMO_ENV_FILE` (default `.env.ocp` in the demo root;
gitignored). Minimum content:

```bash
export DEMO_PLATFORM=openshift
export RHSM_ORG=<org id>
export RHSM_ACTIVATION_KEY=<key>
export IDM_FQDN=idm.<your-domain>
export SAT_FQDN=satellite.<your-domain>
export DEMO_PASSWORD='<password>'      # set it here, otherwise deploy.sh appends one to .env
# optional
# export SATELLITE_API_URL=https://satellite.<your-domain>   # default: https://$SAT_FQDN (must be the name clients use)
# export GITEA_USER=gitops GITEA_REPO=rhel-fleet
# export AAP_MANIFEST=$HOME/Downloads/manifest.zip   # activates AAP without the UI (must contain an AAP subscription)
# export AAP_ENABLED=false                          # skip AAP in 'bootstrap.sh' (all)
```

`scripts/deploy.sh` reads the same variables from the shell:
`set -a; source .env.ocp; set +a; ./scripts/deploy.sh`.

## Bring-up

```bash
export DEMO_ENV_FILE=.env.ocp
gitops/scripts/bootstrap.sh check       # 10 s, changes nothing
gitops/scripts/bootstrap.sh             # all phases, ~10-15 min (+15-25 min with AAP)
```

Full order on a fresh cluster (measured on a nested-virt lab cluster):

```bash
set -a; source .env.ocp; set +a
./scripts/create-rhsm-secret.sh && ./scripts/deploy.sh      # 62 min install + 45 min BaseOS/AppStream sync (on_demand)
gitops/scripts/bootstrap.sh aap                            # in parallel, ~20 min
export DEMO_ENV_FILE=.env.ocp
DEMO_MODE=auto ./scripts/demo-scenarios.sh c1              # 18 min: Dev/QA/Prod, CVs, lc-dev/qa/prod (demo-app 1.0 + web page)
gitops/scripts/prepare-errata.sh                           # 40+ min: RHEL errata cutoff = image date, publish + promote
gitops/scripts/bootstrap.sh                                # 3-5 min: Argo CD, Gitea, runner, seed, apps, webhook, aapconfig
gitops/scripts/prepare-hotfix.sh                           # 1 min: demo-app security erratum for the hotfix act
gitops/scripts/reset.sh --save-baseline                    # remember the start state
```

AAP does not depend on the Satellite. Start it right after `oc login`, in a
second terminal, while `scripts/deploy.sh` installs the Satellite:

```bash
export DEMO_ENV_FILE=.env.ocp
gitops/scripts/bootstrap.sh aap          # operator + instance + password (+ subscription)
```

`aapconfig` (job template) needs Gitea, so it runs after the `gitea` phase;
in `all` it is the last phase before `info`.

| Phase | What | Time |
|---|---|---|
| check | logged in, namespace, Satellite VM, rhsm secret, tools | seconds |
| operator | OpenShift GitOps, waits for Argo CD | 3-6 min |
| gitea | Gitea, admin `gitops` (password = DEMO_PASSWORD), API token to `~/.cache/satellite-demo/gitea-token`, empty public repo | 2-4 min |
| secrets | `fleet-cloudinit-{dev,qa,prod}`, `satellite-cac-credentials` | seconds |
| runner | in-cluster image build (`oc new-build`, Docker strategy) | 2-4 min |
| rbac | namespace label + RoleBinding for Argo CD | seconds |
| seed | pushes `gitops/repo`; `releases.yml` is filled with the versions Satellite serves **now**, so the first sync promotes nothing | 30 s |
| apps | Argo CD apps `rhel-fleet`, `satellite-config` | seconds |
| webhook | Gitea push webhook to Argo CD (else 60 s polling) | seconds |
| aap | AAP 2.7 operator (`stable-2.7`) in namespace `aap`, instance `aap` (gateway + controller, hub and EDA off), admin password to `~/.cache/satellite-demo/aap-admin-password`, subscription from `AAP_MANIFEST` if set | 15-25 min |
| aapconfig | `repo/aap/aap-config.yml` via `infra.aap_configuration`: organization, Gitea API credential, project (internal Gitea URL), inventory, job template **Request RHEL server** with survey | 1-2 min |

**AAP subscription.** Without `AAP_MANIFEST` the first UI login asks for a
manifest or a Red Hat service account (Client ID + Secret), two minutes by
hand; then `bootstrap.sh aapconfig`. A manifest that is already loaded in the
Satellite may or may not be accepted by AAP at the same time; if the upload
fails, use a service account or a separate allocation.

First sync of `satellite-config` runs the Job: structure, patch-wave
membership, registration Secret, releases (no-op). Check it in Argo CD
(satellite-config -> the `satellite-cac` Job -> Logs) or:
`oc logs -n satellite-cloud-native job/satellite-cac -f`.

Re-run any phase on its own, e.g. `bootstrap.sh secrets`. `bootstrap.sh seed --force`
re-seeds the repo and **overwrites its history**.

## Run sheet

Two acts, ~20 minutes in total. Demo 1 (~11 min planned, **13 min measured**
in a literal rehearsal, so keep narration tight or drop the DRIFT proof in
1.2 to save a minute) shows content lifecycle
through Git *and* through the Satellite UI, an incremental hotfix and a
rollback. Demo 2 (~6 min live, its servers boot during Demo 1) shows three
ways to create a server and Satellite configuration as code. Every wait
longer than a minute has narration or parallel work below.

Terminal (demo root): `export DEMO_ENV_FILE=.env.ocp`. Browser tabs, logged
in: Gitea (repo `gitops/rhel-fleet`), Argo CD (apps `rhel-fleet` and
`satellite-config`), Satellite (Content Views -> RHEL9-FullStack -> Versions),
AAP (Templates), OpenShift console (Virtualization -> VirtualMachines). Plus a
separate window with the three host pages tiled side by side (see Opening).

Start state (after `reset.sh` + the T-30 block): Dev, QA and Prod serve the
same RHEL9-FullStack version (baseline, e.g. `5.0`) with demo-app 1.2 on every
host; the next version is published in Library only; the three fallback
servers `*-00` are registered.

**Version numbers in this sheet are examples.** Older versions stay listed in
Satellite after a reset, so the real next version and hotfix version are
higher (e.g. 7.0 and 5.2). Read them from the script output:
`publish-version.sh` prints the new version (demo-app version = its
argument), `release.sh` and `hotfix.sh` print what they change.

**The one rule: merge a `satellite/` PR only when the previous Job has
finished** (Argo CD `satellite-config` shows Synced, not Syncing). A PR merged
while a Job runs gets no Job of its own and the app stays OutOfSync;
**Refresh does not help, press Sync**. `release.sh` warns when a Job is running.

Words to use out loud (avoid "PostSync Job", "composite", "webhook"):
*version* = a frozen snapshot of packages; *environment* = a stage (Dev, QA,
Prod); *promote* = let a stage see a snapshot; *the Job* = the automation
that applies Git to Satellite.

Three numbers that are easy to mix up: `RHEL9-FullStack` is a *composite*
content view (icon with stacked boxes) made of `Demo-App-CV` + `RHEL9-Lifecycle`.
Only the composite is promoted, so `releases.yml` and every PR use the
**composite version** (e.g. 8.0). The components have their own versions
(Demo-App-CV 7.0, RHEL9-Lifecycle 2.1, always in Library), and demo-app has
its RPM version (5.0, shown on the host pages). In the UI look at
RHEL9-FullStack -> Versions, not at Demo-App-CV.

### Before the session (T-30 min)

Argo CD shows no applications after "Log in via OpenShift"? Your user is not
in a group the instance trusts (`cluster-admins`): `oc adm groups new cluster-admins <your user>`,
then log out of Argo CD and in again.

```bash
export DEMO_ENV_FILE=.env.ocp
gitops/scripts/status.sh --hosts               # "Git and Satellite agree", Argo CD Synced, no fleet VMs
gitops/scripts/publish-version.sh <NEXT>       # 90 s: <NEXT> = the version reset.sh printed on its last
                                               # line ("Next: ... publish-version.sh 5.0"); a version that
                                               # already exists is refused
source scripts/demo-scenarios.sh               # run_on_vm, functions only
for h in lc-dev lc-qa lc-prod; do run_on_vm $h "sudo dnf -q makecache"; done   # warm dnf metadata (112 MB AppStream)
# Fallback servers, one per path, registered by the time the session starts (7-8 min):
gitops/scripts/manual-vm.sh legacy-00 dev
gitops/scripts/new-server.sh app-dev-00 dev small --merge
# AAP -> Request RHEL server: app-qa-00 / qa / small / merge without approval: yes
```

### Demo 1 - lifecycle and rollback, through Git and in the UI (~11 min)

**Opening (30 s).** Show the three *host pages* side by side: one browser
window per lifecycle host, tiled next to each other, opened before the session:

- `https://lc-dev-web-satellite-cloud-native.<apps domain>/`
- `https://lc-qa-web-satellite-cloud-native.<apps domain>/`
- `https://lc-prod-web-satellite-cloud-native.<apps domain>/`

(`oc get route -n satellite-cloud-native | grep lc-` lists them.) Each page is
served by demo-app on that host and shows the host name and, in large red
digits, the demo-app version installed there: `v1.2` on all three at the
start. They reload every 10 s, so every later `dnf` step shows up without a
click. Say: "Three
stages, one snapshot each. Today we move a new release through them, once
through Git and once in the Satellite UI you know, then ship a single
security fix to Prod and roll it back."

**1.1 Promote to Dev through Git (3 min)**

```bash
gitops/scripts/release.sh promote dev          # 20 s; defaults to the newest version, e.g. 5.0 -> 6.0
```

Gitea: open the printed compare link -> **New Pull Request** -> **Create
Pull Request** -> the diff is one line -> **Create merge commit**. Argo CD
`satellite-config` starts syncing within seconds; the Job takes ~2 min.
*While it runs:* "The PR is the change request. Here I merge my own PR; in
production branch protection requires a second reviewer, for example
CODEOWNERS so that security approves every Prod line. Who promoted what and
when is `git log satellite/releases.yml`. Satellite's audit log shows the
Job's account; the human is in Git. In production that account is a
dedicated, limited Satellite user, not admin." Then open the Job log
(Argo CD -> satellite-config -> satellite-cac -> Logs): "Dev: 5.0 -> 6.0 (promoted)".

```bash
run_on_vm lc-dev  "sudo dnf -y upgrade demo-app"     # Upgraded demo-app-3.0 -> lc-dev page shows v3.0
run_on_vm lc-prod "sudo dnf -y upgrade demo-app"     # Nothing to do.         -> lc-prod page stays v1.2
```

*Recovery:* no sync after 30 s -> Argo CD **Refresh** on `satellite-config`;
merged while a Job was running (app stays OutOfSync) -> **Sync**, Refresh does
not help. Job failed -> its log; re-run with **Sync**, or `gitops/scripts/run-local.sh --tags releases`.

**1.2 The same promotion in the Satellite UI, recorded in Git (3 min)**

Satellite: Content -> Lifecycle -> Content Views -> RHEL9-FullStack ->
Versions -> row of the new version -> ⋮ -> **Promote** -> tick **QA** ->
**Promote** (~40 s, ~70 s if you still have to log in). "Your way of working stays."

Now prove that Git does not fight the UI. In parallel:
1. Argo CD -> `satellite-config` -> **Sync** (re-applies Git, which still says QA 5.0).
2. Meanwhile: `gitops/scripts/release.sh promote qa` -> "Satellite already
   serves QA=6.0 (promoted outside Git): this PR records it" -> open the PR.
3. The Job log shows "DRIFT QA: Satellite serves 6.0, Git declares 5.0 ...
   left alone. Record it: release.sh record" (`record` and `promote qa` do the
   same here). **Wait until that Job has finished** (Argo CD Synced, ~90 s
   after Sync), then merge the PR (open the compare link -> New Pull Request ->
   Create Pull Request -> Create merge commit). Its Job says "QA: 6.0 (unchanged)".

Say: "For changes made in the UI, Git is the record, not the gate. Recording
can also be a one-line edit in the Gitea web UI." Optional: `run_on_vm lc-qa "sudo dnf -y upgrade demo-app"`
-> the QA page shows the new version too.

**Start Demo 2's servers now** (servers need 7-8 min to register; fleet PRs
do not trigger the satellite-config Job, so they can be merged any time):

```bash
gitops/scripts/manual-vm.sh legacy-01 dev            # V1 by hand
gitops/scripts/new-server.sh app-dev-01 dev small    # V2: prints the compare link -> PR -> merge in Gitea
```

"Two servers are booting, one by hand and one from a pull request. We come
back to them in Demo 2."

**1.3 Hotfix: one security erratum into Prod, nothing else (2.5 min)**

Say first: "This is a demo security erratum for our app. The mechanism is
exactly the same for a Red Hat RHSA; on this lab Satellite that takes one to
two hours, so I show the RHSAs in the UI." Show the erratum: Satellite ->
Content -> Content Types -> Errata -> `DEMO-SA-2026:0002` (Important, demo-app),
and lc-prod's real RHSAs: Hosts -> lc-prod -> Content -> Errata.

```bash
gitops/scripts/hotfix.sh DEMO-SA-2026:0002 prod   # ~85 s: incremental update, Prod 5.0 -> 5.1
```

*While it runs:* "An incremental update copies one erratum into the
snapshot Prod already has, so nothing else rides along. In the UI it is
Content Views -> Demo-App-CV -> Versions -> Errata -> Apply." Then show
Satellite -> RHEL9-FullStack -> Versions: `5.1` in Prod.

```bash
gitops/scripts/release.sh record                  # 13 s: PR "Record Satellite state: Prod 5.0 -> 5.1 (incremental update: DEMO-SA-2026:0002)"
```

Merge it (compare link -> New Pull Request -> Create Pull Request -> Create
merge commit), then:

```bash
run_on_vm lc-prod "sudo dnf -q updateinfo list --available | grep demo"    # only DEMO-SA-2026:0002 Important/Sec.
run_on_vm lc-prod "sudo dnf -y upgrade --advisory DEMO-SA-2026:0002"       # demo-app-1.2.1 -> page "v1.2.1 ... security fix"
```

Prod gets exactly the fix: demo-app 3.0 (Dev/QA) is not offered there.
Published versions never carry `DEMO-SA-*` errata (exclude filter on
Demo-App-CV), so the fix reaches an environment only through this step.
"This emergency path skips QA on purpose; the review of this PR is the control."

**1.4 Rollback through Git (2.5 min)**

"Suppose 1.2.1 breaks the application. We roll back the same way we change things."

```bash
gitops/scripts/release.sh rollback             # PR "Rollback Prod: 5.1 -> 5.0"
```

**Check that the record PR's Job from 1.3 has finished** (Argo CD Synced),
then merge it (same Gitea clicks). The Job promotes the previous version back ("Prod: 5.1 -> 5.0
(promoted)", ~2 min; narrate: "A rollback is a `git revert`, with review and
history like any change. Two halves: Git decides what Prod is *allowed* to
install; the host still *has* 1.2.1 until we undo it"):

```bash
run_on_vm lc-prod "sudo dnf -y history undo last"    # Downgraded demo-app-1.2 -> page v1.2
```

At scale that is a remote execution job on host collection `Patch-Wave-2`.

### Demo 2 - a server three ways, Satellite as code (~6 min live)

**2.1 Recap V1 and V2 (1 min).** Console: `legacy-01` and `app-dev-01`
running (started in 1.2). Gitea: the `app-dev-01` PR, one YAML file. V1:
"It works and registers itself, but who asked for it, who approved it, what
is it for? Nothing records that; Argo CD does not know it either. This is
what your VMware VMs become next year on OpenShift Virtualization: VMs, managed
like everything else."

**2.2 V3 AAP self-service (1.5 min)**

AAP (log in as a named user if one exists, the PR records who asked) ->
Automation Execution -> Templates -> **Request RHEL server** -> Launch
template -> survey: `app-qa-01`, `qa`, `small`, merge without approval
**`no`** -> Next -> Finish. The job takes ~20-30 s and links the PR; merge it in
Gitea (the approval step stays). "Your existing AAP; the job template is
configuration as code; in AAP you use the supported `redhat.satellite` collection."

**2.3 Satellite as code (start, 1 min)**

Why: Demo 1 put *content promotion* in Git; this shows that Satellite's own
configuration is in Git too. `satellite/structure.yml` declares lifecycle
environments, content views, activation keys, host groups, host collections
(patch waves) and RBAC; the same Job applies it on every merge. Say: "A change
to Satellite, including roles that security cares about, is a reviewed PR with
history, and the same file rebuilds the same Satellite after a migration or for
a second site." Patch-Wave-3 is the smallest visible, harmless example, and
patch waves are how this team will roll out patches in stages. If asked: the
Job creates and updates what the file declares but never deletes what is
removed from it (deliberately, so a typo cannot wipe objects).

Gitea: `satellite/structure.yml` -> Edit -> at the end of the
`host_collections` list (after Patch-Wave-2's `hosts_search` line), indented
two spaces like the others, add:

```yaml
  - name: Patch-Wave-3
    description: Pilot wave for the new team
```

-> "Create a new branch ... and start a pull request" -> merge. The Job needs
~1:40; do 2.4 meanwhile. (No `hosts_search`: membership comes from activation
keys or by hand.)

**2.4 The result (2 min)**

Satellite -> Hosts -> All Hosts: `legacy-01` and `app-dev-01` (host group
RHEL9/Dev, lifecycle Dev, collection Patch-Wave-1; registered by now if they
were started in 1.2), `app-qa-01` still registering (show it in the console)
and `app-qa-00` from before the session as its finished state (RHEL9/QA).
"Same template, same registration; only the path and the paper trail differ."
Then Hosts -> Host Collections: `Patch-Wave-3` has appeared.

*Recovery:* no sync after a minute -> **Refresh** on `rhel-fleet`; merge
blocked -> `new-server.sh app-dev-01 dev --merge`; AAP job fails at "Server
does not exist yet" -> the name is taken, pick another; VM stuck in
Provisioning -> `oc get dv -n satellite-cloud-native`; a live host not
registered yet -> show its `*-00` twin.

### Backup for questions (not in the timed flow)

- **Policy as code:** `release.sh promote prod 6.0 --merge` while QA lags
  fails in the Job with "Pipeline order violated ... A version reaches Prod
  only after QA has it". Undo with `release.sh rollback --merge`.
- **Self-heal:** delete `app-dev-01` in the console; Argo CD recreates the VM
  in ~12 s. (Re-registration takes 7-8 min; delete its old host in Satellite afterwards.)
- **"So Prod can change outside Git?"** Yes, for whoever holds the Satellite
  role to promote to Prod. The Job reports anything not recorded in Git as
  DRIFT and `status.sh` shows it; `drift: enforce` in releases.yml turns that
  into strict GitOps.
- **"A registration token that never expires?"** A demo shortcut. It only
  lets a host register with one activation key and host group, it lives only
  in a cluster Secret (never in Git), and in production it gets an expiry; the
  Job regenerates it on every sync. Cluster secrets: Sealed Secrets or External
  Secrets Operator with Vault.
- **"Why is every host red in All Hosts?"** Global status includes errata
  status: the RHEL errata filter leaves security errata applicable but not
  installable, which is the point of the lifecycle. lc-dev/qa/prod were built
  by an older script without host group; fleet hosts have one.
- **"Why do VMs register to Red Hat first?"** The image bootstraps its tools
  from the CDN before Satellite exists in its config; in production the image
  or a kickstart points at Satellite directly.
- **"Who can merge?"** Gitea/GitHub/GitLab branch protection and CODEOWNERS;
  the Job runs with a service account, so nobody needs Satellite admin to ship.

### After the session: reset to the start state (~5 min)

```bash
gitops/scripts/reset.sh --dry-run    # shows what it would do
gitops/scripts/reset.sh              # Git back to gitops/repo + baseline releases, fleet VMs and
                                     # their hosts deleted, undeclared Patch-Wave-N removed,
                                     # lc-* distro-synced, prints the next publish-version.sh version
```

Then the T-30 block again (publish the printed version, fallback servers).
The hotfix erratum stays in Library and can be applied again (the next
incremental update creates x.2). Record a new baseline only from a clean
start state: `reset.sh --save-baseline`.

## How the pieces fit

- **releases.yml**: per environment, the `RHEL9-FullStack` version it should serve. The Job checks the versions exist (no accidental publish), enforces Prod <= QA <= Dev unless `allow_out_of_order: true`, then promotes with force (Katello's own path check would block rollbacks; the order rule is the gate). Unchanged environments are untouched.
- **structure.yml**: declares what c1 builds (environments, content views, composite, keys) plus host groups `RHEL9/{Dev,QA,Prod}`, host collections `Patch-Wave-1/2` with search-based membership, role `Linux-Operator`, user group `linux-operators`. It leaves RHEL repositories in `RHEL9-Lifecycle` alone (they depend on the manifest; no hard-coded ids).
- **Sections are isolated**: releases, structure, host collections and registration each run in their own block; one failing does not stop the others, the Job fails at the end with a summary.
- **Registration**: the Job generates one registration command per environment (activation key + host group, `setup_remote_execution_pull`, non-expiring JWT) into Secret `satellite-registration`. Fleet VMs mount it as disk `satreg`. If it is missing they fall back to c1's `/pub/register-lc-<env>.sh` (key only, no host group).
- **Publishing vs promoting**: publishing a content view version is a build step (`publish-version.sh`). Do not use demo c2 while the GitOps layer is active: c2 promotes to Dev directly, and the next `satellite-config` sync moves Dev back to what Git declares.
- **Supported collection**: the playbooks use `theforeman.foreman` (Galaxy, no token). In AAP use `redhat.satellite`, the supported build of the same modules: replace the prefix.

## Fallbacks

| Broken | Do instead |
|---|---|
| Argo CD / webhook slow | Refresh / Sync buttons; Argo CD polls every 60 s anyway |
| Runner image build failed | `bootstrap.sh runner` again; or `run-local.sh` (podman-built EE, same Git content) |
| Fleet host registered without host group / "no alternative certificate subject name" in `/var/log/client-setup.log` | `SATELLITE_API_URL` must be `https://$SAT_FQDN` (default); `bootstrap.sh secrets`, Sync `satellite-config`, then recreate the VM |
| Live hotfix too slow | it must target Demo-App-CV (`hotfix.sh`), never the RHEL content view (1-2 h) |
| Gitea down | `run-local.sh` uses the local `gitops/repo` and says so; servers via `manual-vm.sh` |
| No AAP | V3 playbook locally (see V3), or show `aap/aap-config.yml` and the survey definition |
| AAP gateway never answers | `oc get pods -n aap`, `oc get aap aap -n aap -o yaml` (status conditions); usually capacity: `oc adm top nodes`, then `AAP_ENABLED=false` and V3 locally |
| `aapconfig` fails with 401/403 or license error | subscription not active: activate in the UI, then `bootstrap.sh aapconfig` again |

## Tear-down

```bash
oc delete applications.argoproj.io -n openshift-gitops rhel-fleet satellite-config   # prunes fleet VMs
oc delete ns gitea
oc delete secret repo-rhel-fleet -n openshift-gitops                                # Argo CD repository entry
# bootstrap.sh set spec.controller.appSync=60s on the (possibly shared) openshift-gitops instance;
# revert if needed: oc patch argocd openshift-gitops -n openshift-gitops --type json -p '[{"op":"remove","path":"/spec/controller/appSync"}]'
oc delete secret -n satellite-cloud-native fleet-cloudinit-dev fleet-cloudinit-qa fleet-cloudinit-prod \
  satellite-cac-credentials satellite-registration
oc delete bc,is satellite-cac-runner -n satellite-cloud-native
oc delete aap aap -n aap --wait; oc delete ns aap   # AAP instance, then operator and namespace
rm -rf ~/.cache/satellite-demo/rhel-fleet ~/.cache/satellite-demo/gitea-token ~/.cache/satellite-demo/aap-admin-password
```

Fleet hosts stay registered in Satellite until deleted there.
