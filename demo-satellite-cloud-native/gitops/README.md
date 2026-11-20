# GitOps layer: servers and Satellite configuration from Git

Adds a GitOps workflow on top of the **OpenShift profile** of this demo
(`DEMO_PLATFORM=openshift`, `scripts/deploy.sh`). One Git repository holds
the RHEL fleet *and* the Satellite configuration. **Argo CD** applies the
fleet (VMs on OpenShift); **Ansible Automation Platform** applies the
Satellite configuration (Event-Driven Ansible starts a job template on every
push) and offers every operator step as a job template.

It shows three ways to create a server side by side, and content lifecycle
(promotion, hotfix, rollback) driven by pull requests, from the CLI, from AAP
or from the Satellite UI.

| | How a server is created | Control | Effort for the requester |
|---|---|---|---|
| **V1 legacy** | Admin creates the VM by hand (CLI, console or AAP), it auto-registers to Satellite | None: no review, no record of who asked | Needs cluster access and know-how |
| **V2 Git PR** | A pull request adds `fleet/<env>/<name>.yaml`; merge = server | Maximum: review, history, revert | Needs Git and YAML |
| **V3 AAP self-service** | AAP survey opens the PR for you, optional auto-merge | Same as V2, approval optional | A form |

All three use the same VM template, cloud-init and Satellite registration;
only the *path* differs.

## Architecture

```
                         Gitea (in cluster)  repo gitops/rhel-fleet
        ┌────────────────────┬──────────────────────┬───────────────────────┐
        │ fleet/<env>/*.yaml │ satellite/           │ aap/  rulebooks/      │
        │ (one VM per file)  │ releases.yml         │ job template playbooks│
        │                    │ structure.yml        │ + AAP config as code  │
        └─────────┬──────────┴──────────┬───────────┴───────────▲───────────┘
                  │ push webhook        │ push webhook (HMAC)   │ PRs via API
     ┌────────────▼──────────┐ ┌────────▼─────────────────┐ ┌───┴──────────────────┐
     │ Argo CD app           │ │ AAP Event Stream -> EDA  │ │ AAP job templates    │
     │ rhel-fleet            │ │ rulebook -> job template │ │ GitOps · (open PRs)  │
     │ auto-sync/prune/heal  │ │ SAT · Apply Satellite as │ │ SAT ·  HOST ·  VM ·  │
     └────────────┬──────────┘ │ code (queued, 1 at a time│ └──────┬───────────────┘
                  │            └────────┬─────────────────┘        │ Satellite API / REX
                  ▼                     │ redhat.satellite          ▼
   VirtualMachine on OpenShift Virt     ▼                    Satellite: publish, hotfix,
     cloud-init: fleet-cloudinit-<env>  Satellite: lifecycle envs, CVs, keys,   package
     disk satreg: registration command ◀ host groups, patch waves, RBAC,   updates on hosts
     (activation key + host group)        promotion per releases.yml,     (remote execution,
                  │                       Secret satellite-registration    pull-mqtt)
                  └──── registers ───▶ Satellite (Dev / QA / Prod)

   V1: CLI / console / "VM · Create server by hand" ──▶ same VirtualMachine, not in Git
```

What lives where:

| In Git (Gitea) | Only in the cluster / AAP |
|---|---|
| VM manifests, `releases.yml`, `structure.yml`, VM template, Satellite playbook, AAP playbooks, EDA rulebook, AAP config as code | `fleet-cloudinit-<env>` (demo password), `satellite-registration` (registration JWTs), `rhsm-credentials`, AAP credentials (Satellite API, OpenShift token of `aap-demo`, Gitea token, event stream HMAC secret) |

Production path for the cluster-only secrets: External Secrets Operator
(Vault, cloud secret manager) or Sealed Secrets, so they can be versioned too.

## Directory layout

```
gitops/
  bootstrap/               cluster-side setup, applied by bootstrap.sh (not synced by Argo CD)
    gitops-operator.yaml   OpenShift GitOps Subscription (skipped when already installed)
    gitea.yaml             Gitea (Deployment, PVC, Service, Route)
    argocd-rbac.yaml       Argo CD may manage the demo namespace
    applications.yaml      Argo CD app rhel-fleet (+ satellite-config only with SATELLITE_EXECUTOR=argo)
    aap-operator.yaml      AAP 2.7 operator
    aap-instance.yaml      AAP instance: gateway, controller, EDA
    aap-rbac.yaml          ServiceAccount aap-demo (namespace Role) + EE image pull for AAP
    fleet-cloudinit-secret.yaml.tpl  per-env cloud-init (rendered from the env file)
  runner/Containerfile     "GitOps EE": AAP ee-supported (redhat.satellite, kubernetes.core) + rpm-build
  repo/                    seeded into Gitea as gitops/rhel-fleet
    fleet/                 one VirtualMachine per file
    templates/vm.yaml.j2   the VM template (V1, V2, V3)
    satellite/             site.yml, structure.yml, releases.yml, tasks/ (+ Job/kustomization for the argo executor)
    rulebooks/             EDA rulebook: push to main -> SAT · Apply Satellite as code
    aap/                   job template playbooks, tasks/, files/demo-app.spec.j2, aap-config.yml
  scripts/
    bootstrap.sh           bring-up, phase by phase, idempotent
    aap-run.sh             launch any AAP job template from the terminal and wait
    manual-vm.sh           V1
    new-server.sh          V2 (branch + PR link, or --open-pr / --merge)
    release.sh             promote dev|qa|prod [VERSION] / record / rollback, as a PR
    publish-version.sh     build demo-app RPM + publish CVs (no promotion)
    hotfix.sh              incremental update: one erratum into the version an environment serves
    prepare-errata.sh      one-time: errata date filter on RHEL9-Lifecycle (real RHSAs become "applicable")
    prepare-hotfix.sh      one-time: demo-app security erratum (repo with updateinfo, exclude filter)
    reset.sh               back to the start state (Git, branches, fleet VMs + hosts, patch waves, lc-* packages)
    status.sh              Git vs Satellite vs hosts vs Argo CD, last apply run, drift line
    render-runsheet.sh     this README as an HTML page with your links and credentials (not committed)
    run-local.sh           fallback: run the Satellite playbook from the laptop
```

AAP job templates (`repo/aap/aap-config.yml`) and their CLI twins:

| Template | Playbook | CLI twin |
|---|---|---|
| GitOps · Promote release | `aap/promote-release.yml` | `release.sh promote` |
| GitOps · Record Satellite state | `aap/record-state.yml` | `release.sh record` |
| GitOps · Roll back last release | `aap/rollback-release.yml` | `release.sh rollback` |
| GitOps · Request RHEL server | `aap/create-server-pr.yml` | `new-server.sh` |
| SAT · Apply Satellite as code | `satellite/site.yml` (EDA) | `run-local.sh` |
| SAT · Publish new version | `aap/publish-version.yml` | `publish-version.sh` |
| SAT · Hotfix (incremental update) | `aap/hotfix.yml` | `hotfix.sh` |
| SAT · Status | `aap/status.yml` | `status.sh` |
| HOST · Update package | `aap/host-update.yml` | `run_on_vm <host> "dnf upgrade ..."` |
| HOST · Undo last package transaction | `aap/host-undo.yml` | `run_on_vm <host> "dnf history undo last"` |
| VM · Create server by hand (V1) | `aap/create-vm-by-hand.yml` | `manual-vm.sh` |

## Prerequisites

- OpenShift 4.14+ with OpenShift Virtualization, DataSource `rhel9`, RWO storage, internal image registry, image builds.
- The base demo deployed with the OpenShift profile: `scripts/deploy.sh` (IdM, Satellite), manifest uploaded, and **demo c1 run** (`scripts/demo-scenarios.sh c1`): it creates Dev/QA/Prod, `RHEL9-FullStack`, the `rhel9-lc-*` keys, the `/pub/register-lc-*.sh` fallback scripts and lc-dev/qa/prod.
- Laptop: `oc`, `virtctl`, `sshpass`, `git`, `curl`, `ansible` (template rendering), `python3`; `infra.aap_configuration`, `ansible.platform`, `ansible.controller`, `ansible.eda` for `bootstrap.sh aapconfig`. For `run-local.sh`: `ansible-navigator`, `podman` and a one-time `podman login registry.redhat.io`.
- AAP runs **on the same cluster** (`bootstrap.sh aap`: AAP 2.7 operator, gateway + controller + EDA). Its default EE `ee-supported-rhel9` already contains `redhat.satellite` and `kubernetes.core`, so no Automation Hub token is needed.
- Capacity: Satellite 4 vCPU / 22 GiB, IdM 2 / 4, clients 1 / 2 each, AAP with EDA roughly 5 vCPU / 12 GiB in requests, plus OpenShift GitOps and Gitea. Check `oc adm top nodes` before the bring-up.

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
# export SATELLITE_EXECUTOR=argo                    # default aap (EDA + job template); argo = PostSync Job fallback
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
gitops/scripts/bootstrap.sh             # all phases, ~10-15 min (+20-30 min for AAP)
```

Full order on a fresh cluster (measured on a nested-virt lab cluster):

```bash
set -a; source .env.ocp; set +a
./scripts/create-rhsm-secret.sh && ./scripts/deploy.sh      # 62 min install + 45 min BaseOS/AppStream sync (on_demand)
gitops/scripts/bootstrap.sh aap                            # in parallel, ~25 min (gateway, controller, EDA)
export DEMO_ENV_FILE=.env.ocp
DEMO_MODE=auto ./scripts/demo-scenarios.sh c1              # 18 min: Dev/QA/Prod, CVs, lc-dev/qa/prod (demo-app 1.0 + web page)
gitops/scripts/prepare-errata.sh                           # 40+ min: RHEL errata cutoff = image date, publish + promote
gitops/scripts/bootstrap.sh                                # 5-8 min: Argo CD, Gitea, EE build, seed, apps, webhooks, AAP config
gitops/scripts/prepare-hotfix.sh                           # 1 min: demo-app security erratum for the hotfix act
gitops/scripts/reset.sh --save-baseline                    # remember the start state
gitops/scripts/render-runsheet.sh                          # the run sheet as an HTML page with your links
```

AAP does not depend on the Satellite. Start it right after `oc login`, in a
second terminal, while `scripts/deploy.sh` installs the Satellite.

| Phase | What | Time |
|---|---|---|
| check | logged in, namespace, Satellite VM, rhsm secret, tools | seconds |
| operator | OpenShift GitOps (reuses an installed operator), waits for Argo CD | 0-6 min |
| gitea | Gitea, admin `gitops` (password = DEMO_PASSWORD), API token to `~/.cache/satellite-demo/gitea-token`, empty public repo | 2-4 min |
| secrets | `fleet-cloudinit-{dev,qa,prod}`, `satellite-cac-credentials`, placeholder `satellite-registration` | seconds |
| runner | "GitOps EE" image build in the cluster (`FROM ee-supported-rhel9`) | 2-4 min |
| rbac | namespace label + RoleBinding for Argo CD | seconds |
| seed | pushes `gitops/repo`; `releases.yml` gets the versions Satellite serves **now**, so the first run promotes nothing | 30 s |
| apps | Argo CD app `rhel-fleet` (+ `satellite-config` only with `SATELLITE_EXECUTOR=argo`) | seconds |
| webhook | Gitea push webhook to Argo CD | seconds |
| aap | AAP 2.7 operator, instance `aap` (gateway, controller, EDA), EDA initial data, admin password to `~/.cache/satellite-demo/aap-admin-password`, subscription from `AAP_MANIFEST` if set | 20-30 min |
| aapconfig | `aap-rbac.yaml`, then `repo/aap/aap-config.yml` via `infra.aap_configuration`: credentials, "GitOps EE", project, all job templates with surveys, EDA (event stream, rulebook activation); Gitea webhook to the event stream | 2-3 min |

**AAP subscription.** Without `AAP_MANIFEST` the first UI login asks for a
manifest or a Red Hat service account (Client ID + Secret), two minutes by
hand; then `bootstrap.sh aapconfig`. The Satellite subscription manifest was
accepted by AAP in the rehearsal (an allocation with an AAP-capable SKU).

The first push that touches `satellite/` after `aapconfig` runs **SAT · Apply
Satellite as code** fully: structure, patch-wave membership, registration
Secret, releases (no-op). Launch it by hand once to check it right away. See it
in AAP -> Jobs, or `gitops/scripts/status.sh` ("last apply run").

Re-run any phase on its own, e.g. `bootstrap.sh secrets`. `bootstrap.sh seed --force`
re-seeds the repo and **overwrites its history**. `AAP_RECREATE_ACTIVATION=true
bootstrap.sh aapconfig` recreates the rulebook activation (EDA refuses to update
a running one).

## Run sheet

Two acts, ~20 minutes. Demo 1 (~11-13 min) moves content through Dev, QA and
Prod through Git *and* in the Satellite UI, ships one security fix to Prod and
rolls it back. Demo 2 (~6 min live, its servers boot during Demo 1) creates a
server three ways and changes Satellite through Git.

**Every step lists its alternatives.** Pick one per step; all of them end in
the same state:

| Label | Where | Notes |
|---|---|---|
| `AAP ▸` | AAP -> Automation Execution -> Templates -> template -> Launch | the default live path; same templates from a terminal: `gitops/scripts/aap-run.sh "<template>" key=value` |
| `Satellite UI ▸` | Satellite web UI | for the team that knows Satellite |
| `Gitea ▸` | Gitea web UI | pull requests, web editor |
| `Console ▸` | OpenShift console | VMs |
| `CLI ▸` | terminal, demo root, `export DEMO_ENV_FILE=.env.ocp` | fast path and fallback |

Template prefixes: `GitOps ·` opens a pull request, `SAT ·` acts on Satellite,
`HOST ·` acts on hosts through Satellite remote execution, `VM ·` acts on
OpenShift outside Git.

**How a merge reaches Satellite:** Gitea push -> AAP Event Stream -> EDA
rulebook -> job template **SAT · Apply Satellite as code** (AAP -> Jobs). The
job starts ~3 s after the merge and finishes 75-95 s after it. One runs at a
time: while one runs, the next merge's job appears only when the first one
ends (EDA holds the event), and every merge is applied, so PRs can be merged
back to back. A merge that changes nothing under `satellite/` (a new server)
also starts the job, which exits after ~15 s without touching Satellite. Argo
CD only manages the VMs (`rhel-fleet`).

**Gitea merges:** on the PR page click **Create merge commit** and tick
**Delete branch** (left-over branches pile up otherwise; `reset.sh` deletes them).

Values in `{{…}}` (links, passwords, the next version) are filled in by
`gitops/scripts/render-runsheet.sh`, which renders this file into an HTML page
with your cluster's links and credentials (`~/.cache/satellite-demo/runsheet.html`,
never committed).

Words to use out loud (avoid "PostSync", "composite", "webhook"): *version* =
a frozen snapshot of packages; *environment* = a stage (Dev, QA, Prod);
*promote* = let a stage see a snapshot; *the job* = the automation that
applies Git to Satellite.

Three numbers that are easy to mix up: `RHEL9-FullStack` is a *composite*
content view (icon with stacked boxes) made of `Demo-App-CV` + `RHEL9-Lifecycle`.
Only the composite is promoted, so `releases.yml` and every PR use the
**composite version** (e.g. 10.0). The components have their own versions
(always in Library) and demo-app has its RPM version (shown on the host pages).
In the UI look at RHEL9-FullStack -> Versions, not at Demo-App-CV.
**Version numbers below are examples**: scripts and jobs print the real ones.

### Connections

| System | URL | Login |
|---|---|---|
| Satellite | {{SAT_URL}} | admin / {{DEMO_PASSWORD}} |
| AAP | {{AAP_URL}} | admin / {{AAP_PASSWORD}} |
| Gitea | {{GITEA_REPO_URL}} | {{GITEA_USER}} / {{DEMO_PASSWORD}} |
| Argo CD | {{ARGOCD_URL}} | Log in via OpenShift |
| OpenShift console | {{CONSOLE_URL}} | your OpenShift user |
| Host page lc-dev | {{LC_DEV_URL}} | - |
| Host page lc-qa | {{LC_QA_URL}} | - |
| Host page lc-prod | {{LC_PROD_URL}} | - |

Argo CD shows no applications after "Log in via OpenShift"? Your user is not
in a group the instance trusts: `oc adm groups new cluster-admins <your user>`,
then log out of Argo CD and in again.

### Before the session (T-30 min)

Browser: the tabs above, logged in, plus one window with the three host pages
tiled side by side. Terminal: `export DEMO_ENV_FILE=.env.ocp`.

1. **Check the start state** (Git and Satellite agree on {{BASELINE}}, no fleet VMs).
   - `AAP ▸` **SAT · Status** (Git vs Satellite only; fleet VMs: Console -> Virtualization)
   - `CLI ▸` `gitops/scripts/status.sh --hosts` (both)
2. **Publish the next version** (~95 s; demo-app {{NEXT_VERSION}}, an existing version is refused).
   - `AAP ▸` **SAT · Publish new version**, demo-app version `{{NEXT_VERSION}}`
   - `CLI ▸` `gitops/scripts/publish-version.sh {{NEXT_VERSION}}`
3. **Warm the dnf metadata** on the lifecycle hosts (112 MB AppStream once).
   - `CLI ▸` `source scripts/demo-scenarios.sh; for h in lc-dev lc-qa lc-prod; do run_on_vm $h "sudo dnf -q makecache"; done`
4. **Fallback servers** (registered by the time the session starts, 5-8 min).
   Only `app-qa-00` is really needed (V3 cannot register within the act);
   the other two are insurance.
   - `AAP ▸` **GitOps · Request RHEL server**: `app-qa-00`, `qa`, `small`, merge `yes`
   - `AAP ▸` **VM · Create server by hand (V1)**: `legacy-00`, `dev` (optional)
   - `CLI ▸` `gitops/scripts/new-server.sh app-dev-00 dev small --merge` (optional)

### Demo 1 - lifecycle and rollback, through Git and in the UI (~11-13 min)

**Opening (30 s).** The three host pages side by side ([lc-dev]({{LC_DEV_URL}}),
[lc-qa]({{LC_QA_URL}}), [lc-prod]({{LC_PROD_URL}})): each shows the host name and, in large red
digits, the demo-app version installed there, the same on all three at the
start. They reload every 10 s, so every later package step shows up without
a click. Say: "Three stages, one snapshot each. Today we move a new release
through them, once through Git and once in the Satellite UI you know, then ship
a single security fix to Prod and roll it back."

**1.1 Promote to Dev through Git (3 min)**

- `AAP ▸` **GitOps · Promote release**: environment `dev`, version empty
  (= newest), merge `no` -> the job (~30 s) links the PR. `Gitea ▸` open it ->
  the diff is one line -> **Create merge commit**.
- `CLI ▸` `gitops/scripts/release.sh promote dev` (20 s) -> open the printed
  compare link -> **New Pull Request** -> **Create Pull Request** -> **Create merge commit**.

AAP -> Jobs: **SAT · Apply Satellite as code** starts ~3 s after the merge and
finishes ~80-95 s after it. *While it runs:* "The PR is the change request. Here I merge my own PR;
in production branch protection requires a second reviewer, for example
CODEOWNERS so that security approves every Prod line. Who promoted what and
when is `git log satellite/releases.yml`. Satellite's audit log shows the job's
account; the human is in Git." Point at the job output: "Dev: {{BASELINE}} -> {{NEXT_CV_VERSION}} (promoted)".

Then update the hosts (lc-dev gets the new version, lc-prod has nothing to do):

- `AAP ▸` **HOST · Update package**: hosts `name ~ lc-dev or name ~ lc-prod`,
  package `demo-app` (~40 s, output per host)
- `Satellite UI ▸` Hosts -> All Hosts -> tick lc-dev and lc-prod -> **Schedule a
  job** -> Job category **Katello** -> Job template **Update Package - Katello
  Script Default** -> **Next** -> package `demo-app` -> **Skip to review** ->
  **Submit** (the target step may briefly show "Apply to 0 hosts"; the job still
  runs on both; ~25 s)
- `CLI ▸` `run_on_vm lc-dev "sudo dnf -y upgrade demo-app"` and the same for lc-prod ("Nothing to do.")

The lc-dev page turns to the new version, lc-prod stays.

*Recovery:* no apply job 30 s after the merge **and none running** -> AAP ->
Templates -> **SAT · Apply Satellite as code** -> Launch (it applies the current
Git state). If one is running, the next one appears when it ends. Job failed ->
its output in AAP; fallback `CLI ▸ gitops/scripts/run-local.sh --tags releases`.

**1.2 The same promotion in the Satellite UI, recorded in Git (3 min)**

- `Satellite UI ▸` Content -> Lifecycle -> Content Views -> RHEL9-FullStack ->
  Versions -> row of the new version -> ⋮ -> **Promote** -> tick **QA** ->
  **Promote** (~40 s). "Your way of working stays."

Prove that Git does not fight the UI (optional, +1.5 min): AAP -> Templates ->
**SAT · Apply Satellite as code** -> Launch. Its output says "DRIFT QA:
Satellite serves {{NEXT_CV_VERSION}}, Git declares {{BASELINE}} ... left alone"
(it suggests `release.sh record`; the AAP twin is **GitOps · Record Satellite
state**): the job re-applied Git and did not undo the UI promotion.

Record the UI promotion in Git:

- `AAP ▸` **GitOps · Record Satellite state** (merge `no`) -> PR "Record
  Satellite state: QA {{BASELINE}} -> {{NEXT_CV_VERSION}}" -> `Gitea ▸` merge
- `AAP ▸` alternatively **GitOps · Promote release**: `qa` (the PR notes that
  Satellite already serves it)
- `CLI ▸` `gitops/scripts/release.sh promote qa` (or `record`) -> merge in Gitea

The apply job says "QA: {{NEXT_CV_VERSION}} (unchanged)" - don't wait for it,
go straight on. Say: "For changes made in the UI, Git is the record, not the
gate." Optional: update lc-qa as in 1.1.

**Start Demo 2's servers now** (5-8 min to register; a fleet merge starts the
apply job too, but it exits in ~15 s without touching Satellite):

- `AAP ▸` **VM · Create server by hand (V1)**: `legacy-01`, `dev`
  (survey also has Size, default small; or `Console ▸` Virtualization ->
  VirtualMachines -> Create -> With YAML, paste `gitops/scripts/manual-vm.sh legacy-01 dev --print`)
- `CLI ▸` `gitops/scripts/manual-vm.sh legacy-01 dev`
- V2, the Git path: `CLI ▸` `gitops/scripts/new-server.sh app-dev-01 dev small` ->
  open the compare link -> PR -> merge (or `Gitea ▸` web editor: new file
  `fleet/dev/app-dev-01.yaml`)

"Two servers are booting, one by hand and one from a pull request. We come
back to them in Demo 2."

**1.3 Hotfix: one security erratum into Prod, nothing else (3 min)**

Say first: "This is a demo security erratum for our app. The mechanism is
exactly the same for a Red Hat RHSA; on this lab Satellite that takes one to
two hours, so I show the RHSAs in the UI." `Satellite UI ▸` Content -> Content
Types -> Errata -> `DEMO-SA-2026:0002` (Important, demo-app), and lc-prod's
real RHSAs: Hosts -> lc-prod -> Content -> Errata.

Incremental update (~90 s):

- `AAP ▸` **SAT · Hotfix (incremental update)**: erratum `DEMO-SA-2026:0002`,
  environment `prod` -> "Prod: RHEL9-FullStack {{BASELINE}} -> a new minor
  version" (e.g. 5.1; higher after earlier rehearsals)
- `CLI ▸` `gitops/scripts/hotfix.sh DEMO-SA-2026:0002 prod`

*While it runs:* "An incremental update copies one erratum into the snapshot
Prod already has, so nothing else rides along." Then `Satellite UI ▸`
RHEL9-FullStack -> Versions: the new minor version in Prod.

Record it in Git, then install exactly this fix on lc-prod:

- `AAP ▸` **GitOps · Record Satellite state** -> PR "Record Satellite state:
  Prod {{BASELINE}} -> <minor>" -> `Gitea ▸` merge
- `CLI ▸` `gitops/scripts/release.sh record` -> merge
- `AAP ▸` **HOST · Update package**: hosts `name ~ lc-prod`, leave package
  `demo-app`, erratum `DEMO-SA-2026:0002` -> page "v1.2.1 ... security fix"
  (the job output shows "FAILED - RETRYING: Wait for the hosts" while it polls;
  that is not an error)
- `Satellite UI ▸` Hosts -> lc-prod -> Content -> Errata -> tick
  `DEMO-SA-2026:0002` -> **Apply** (via remote execution)
- `CLI ▸` `run_on_vm lc-prod "sudo dnf -y upgrade --advisory DEMO-SA-2026:0002"`

Prod gets exactly the fix: the new release from Dev/QA is not offered there.
Published versions never carry `DEMO-SA-*` errata (exclude filter on
Demo-App-CV), so the fix reaches an environment only through this step.
"This emergency path skips QA on purpose; the review of this PR is the control."

**1.4 Rollback through Git (2.5 min)**

"Suppose 1.2.1 breaks the application. We roll back the same way we change things."

- `AAP ▸` **GitOps · Roll back last release** -> PR "Rollback Prod: <minor> -> {{BASELINE}}"
  -> `Gitea ▸` merge
- `CLI ▸` `gitops/scripts/release.sh rollback` -> merge

The apply job promotes the previous version back ("Prod: <minor> -> {{BASELINE}}
(promoted)", ~90 s). Narrate: "A rollback is a revert, with review and history
like any change. Two halves: Git decides what Prod is *allowed* to install;
the host still *has* 1.2.1 until we undo it":

- `AAP ▸` **HOST · Undo last package transaction**: hosts `name ~ lc-prod`
- `Satellite UI ▸` Hosts -> lc-prod -> **Schedule a job** -> Job category
  **Commands** -> **Run Command - Script Default** -> **Next** -> command
  `dnf -y history undo last` -> **Skip to review** -> **Submit**
- `CLI ▸` `run_on_vm lc-prod "sudo dnf -y history undo last"`

The lc-prod page goes back to v1.2. At scale that is the same remote execution
job on host collection `Patch-Wave-2`.

### Demo 2 - a server three ways, Satellite as code (~6 min live)

**2.1 Recap V1 and V2 (1 min).** Console: `legacy-01` and `app-dev-01`
running (started in 1.2). Gitea: the `app-dev-01` PR, one YAML file. V1:
"It works and registers itself, but who asked for it, who approved it, what
is it for? Nothing records that; Argo CD does not know it either. This is what
your VMware VMs become next year on OpenShift Virtualization: VMs, managed like
everything else."

**2.2 V3 AAP self-service (1.5 min)**

- `AAP ▸` **GitOps · Request RHEL server**: `app-qa-01`, `qa`, `small`, merge
  **`no`** -> the job (~20 s) links the PR -> `Gitea ▸` merge (the approval step stays)

"Your existing AAP; the job template is configuration as code; the Satellite
side uses the supported `redhat.satellite` collection." Log in to AAP as a
named user if one exists: the PR records who asked.

**2.3 Satellite as code (start, 1 min)**

Why: Demo 1 put *content promotion* in Git; this shows that Satellite's own
configuration is in Git too. `satellite/structure.yml` declares lifecycle
environments, content views, activation keys, host groups, host collections
(patch waves) and RBAC; the same AAP job applies it on every merge. Say: "A
change to Satellite, including roles that security cares about, is a reviewed
PR with history, and the same file rebuilds the same Satellite after a
migration or for a second site." Patch-Wave-3 is the smallest visible, harmless
example, and patch waves are how this team will roll out patches in stages. If
asked: the job creates and updates what the file declares but never deletes
what is removed from it (deliberately, so a typo cannot wipe objects).

- `Gitea ▸` `satellite/structure.yml` -> Edit -> at the end of the
  `host_collections` list (after Patch-Wave-2's `hosts_search` line), indented
  two spaces like the others, add the two lines below -> "Create a new branch
  ... and start a pull request" -> merge.

```yaml
  - name: Patch-Wave-3
    description: Pilot wave for the new team
```

The apply job needs ~85 s; do 2.4 meanwhile. Its summary has no line naming
Patch-Wave-3 (only the "Host collections" task shows as changed): show the
result in Satellite -> Hosts -> Host Collections instead.

**2.4 The result (2 min)**

`Satellite UI ▸` Hosts -> All Hosts: `legacy-01` and `app-dev-01` with host
group RHEL9/Dev (open one host page for lifecycle Dev and collection
Patch-Wave-1; the list shows only the host group; all are registered by now if
they were started in 1.2), `app-qa-01` still registering (show it in the console)
and `app-qa-00` from before the session as its finished state (RHEL9/QA).
"Same template, same registration; only the path and the paper trail differ."
Then Hosts -> Host Collections: `Patch-Wave-3` has appeared.

*Recovery:* VM not created after a minute -> Argo CD **Refresh** on
`rhel-fleet`; merge blocked -> `CLI ▸ new-server.sh app-dev-01 dev --merge`;
AAP job fails at "Server does not exist yet" -> the name is taken, pick another;
VM stuck in Provisioning -> `oc get dv -n satellite-cloud-native`; a live host
not registered yet -> show its `*-00` twin; a host never picks up a remote
execution job -> `run_on_vm <host> "sudo systemctl restart yggdrasild"`.

### Backup for questions (not in the timed flow)

- **Policy as code:** `AAP ▸` **GitOps · Promote release** `prod`, version of
  Dev, merge `yes` while QA lags -> the apply job fails with "Pipeline order
  violated ... A version reaches Prod only after QA has it". Undo with
  **GitOps · Roll back last release**.
- **Self-heal:** delete `app-dev-01` in the console; Argo CD recreates the VM
  in ~12 s. (Re-registration takes 7-8 min; delete its old host in Satellite afterwards.)
- **"So Prod can change outside Git?"** Yes, for whoever holds the Satellite
  role to promote to Prod. The job reports anything not recorded in Git as
  DRIFT and **SAT · Status** shows it; `drift: enforce` in releases.yml turns
  that into strict GitOps.
- **"A registration token that never expires?"** A demo shortcut. It only
  lets a host register with one activation key and host group, it lives only
  in a cluster Secret (never in Git), and in production it gets an expiry; the
  job regenerates it on every run. Cluster secrets: Sealed Secrets or External
  Secrets Operator with Vault.
- **"Why is every host red in All Hosts?"** Global status includes errata
  status: the RHEL errata filter leaves security errata applicable but not
  installable, which is the point of the lifecycle. lc-dev/qa/prod were built
  by an older script without host group; fleet hosts have one.
- **"Why do VMs register to Red Hat first?"** The image bootstraps its tools
  from the CDN before Satellite exists in its config; in production the image
  or a kickstart points at Satellite directly.
- **"Who can merge? Who can run the AAP templates?"** Gitea/GitHub/GitLab
  branch protection and CODEOWNERS for merges; AAP RBAC (teams, execute
  permission per template) for the templates. The apply job runs with a
  service credential, so nobody needs Satellite admin to ship.

### After the session: reset to the start state (~6 min)

- `CLI ▸` `gitops/scripts/reset.sh --dry-run`, then `gitops/scripts/reset.sh`:
  Git back to `gitops/repo` + baseline releases, all branches except main
  deleted, fleet VMs and their hosts deleted, undeclared Patch-Wave-N removed,
  lc-* packages back to what they are served; prints the next version.

Then the T-30 block again. The hotfix erratum stays in Library and can be
applied again (the next incremental update creates x.2). Record a new baseline
only from a clean start state: `reset.sh --save-baseline`.

## How the pieces fit

- **releases.yml**: per environment, the `RHEL9-FullStack` version it should serve. The apply job checks the versions exist (no accidental publish), enforces Prod <= QA <= Dev unless `allow_out_of_order: true`, then promotes with force (Katello's own path check would block rollbacks; the order rule is the gate). It acts only on environments whose declaration changed since its last run; anything else that differs is reported as DRIFT (UI changes are never silently undone).
- **structure.yml**: declares what c1 builds (environments, content views, composite, keys) plus host groups `RHEL9/{Dev,QA,Prod}`, host collections `Patch-Wave-1/2` with search-based membership, role `Linux-Operator`, user group `linux-operators`. It leaves RHEL repositories in `RHEL9-Lifecycle` alone (they depend on the manifest; no hard-coded ids).
- **Sections are isolated**: releases, structure, host collections and registration each run in their own block; one failing does not stop the others, the job fails at the end with a summary.
- **Registration**: the job generates one registration command per environment (activation key + host group, `setup_remote_execution_pull`, non-expiring JWT) into Secret `satellite-registration`. Fleet VMs mount it as disk `satreg`. If it is missing they fall back to c1's `/pub/register-lc-<env>.sh` (key only, no host group).
- **Who applies satellite/**: `SATELLITE_EXECUTOR=aap` (default): Gitea webhook -> AAP event stream `gitea_push` -> rulebook activation `satellite_as_code` -> job template **SAT · Apply Satellite as code** (one at a time, merges queue). Pushes that change nothing under `satellite/` end after ~15 s. `SATELLITE_EXECUTOR=argo`: Argo CD app `satellite-config` runs the same playbook as a PostSync Job (fallback; merges during a running Job need a manual Sync).
- **Publishing vs promoting**: publishing a content view version is a build step (**SAT · Publish new version** / `publish-version.sh`). Do not use demo c2 while the GitOps layer is active: c2 promotes to Dev directly, and the next apply run reports it as DRIFT.
- **Remote execution on hosts**: the `HOST ·` templates and the Satellite UI use the script provider over pull-mqtt (Satellite cannot SSH into masquerade-networked VMs). cloud-init keeps `yggdrasild` restarting (`Restart=always`), otherwise a broker hiccup at boot leaves jobs pending forever.
- **Collections**: `redhat.satellite` and `kubernetes.core` from AAP's supported EE; the runner image ("GitOps EE") adds `rpm-build` for demo-app builds.

## Fallbacks

| Broken | Do instead |
|---|---|
| No apply job after a merge | AAP -> Templates -> **SAT · Apply Satellite as code** -> Launch; check the rulebook activation `satellite_as_code` (AAP -> Automation Decisions) and the Gitea webhook delivery (repo -> Settings -> Webhooks) |
| EDA down | launch the apply template by hand after each merge, or switch the executor: set `export SATELLITE_EXECUTOR=argo` **in the env file** (every script reads it) and run `bootstrap.sh apps` (Argo CD PostSync Job; the activation is disabled and the EDA webhook removed). Back: remove the line, `bootstrap.sh apps` |
| AAP down | every step has a `CLI ▸` twin; `run-local.sh` applies `satellite/` from the laptop |
| EE image build failed | `bootstrap.sh runner` again; meanwhile set the templates' execution environment to AAP's "Default execution environment" (all but **SAT · Publish new version** run there) |
| REX job stays "pending" | `run_on_vm <host> "sudo systemctl restart yggdrasild"` (older hosts without the restart drop-in) |
| Fleet host registered without host group / "no alternative certificate subject name" in `/var/log/client-setup.log` | `SATELLITE_API_URL` must be `https://$SAT_FQDN` (default); `bootstrap.sh secrets aapconfig`, launch the apply template, then recreate the VM |
| Live hotfix too slow | it must target Demo-App-CV (**SAT · Hotfix** / `hotfix.sh`), never the RHEL content view (1-2 h) |
| Gitea down | `run-local.sh` uses the local `gitops/repo` and says so; servers via `manual-vm.sh` |
| AAP gateway never answers | `oc get pods -n aap`, `oc get aap aap -n aap -o yaml` (status conditions); usually capacity: `oc adm top nodes` |
| `aapconfig` fails with 401/403 or license error | subscription not active: activate in the UI, then `bootstrap.sh aapconfig` again |
| Rulebook activation create fails with HTTP 500 | `oc exec -n aap deploy/aap-eda-api -c eda-api -- aap-eda-manage create_initial_data`, then `bootstrap.sh aapconfig` |

## Tear-down

```bash
oc delete applications.argoproj.io -n openshift-gitops rhel-fleet   # prunes fleet VMs
oc delete ns gitea
oc delete secret repo-rhel-fleet -n openshift-gitops                # Argo CD repository entry
# bootstrap.sh set spec.controller.appSync=60s on the (possibly shared) openshift-gitops instance;
# revert if needed: oc patch argocd openshift-gitops -n openshift-gitops --type json -p '[{"op":"remove","path":"/spec/controller/appSync"}]'
oc delete secret -n satellite-cloud-native fleet-cloudinit-dev fleet-cloudinit-qa fleet-cloudinit-prod \
  satellite-cac-credentials satellite-registration aap-demo-token
oc delete -f gitops/bootstrap/aap-rbac.yaml --ignore-not-found
oc delete bc,is satellite-cac-runner -n satellite-cloud-native
oc delete aap aap -n aap --wait; oc delete ns aap   # AAP (controller, EDA), then operator and namespace
rm -rf ~/.cache/satellite-demo/{rhel-fleet,gitea-token,aap-admin-password,eda-webhook-secret,runsheet.html}
```

Fleet hosts stay registered in Satellite until deleted there.
