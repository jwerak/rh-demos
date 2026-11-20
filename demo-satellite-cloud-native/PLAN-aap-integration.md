# Plan: AAP as the operator interface and the Satellite executor

Status: **implemented 2026-11-20** (P0-P6 done; D4 optional template not built). Decisions: D1 = EDA, D2 = prefix scheme as
proposed, D3 = `redhat.satellite`, D4 = reset as an optional last package,
D5 = baseline committed before P0.

## Goal

1. Every step the presenter runs from the CLI today gets an **AAP job
   template alternative**, named with a clear prefix. Where it makes sense,
   updating packages on hosts also works from the **Satellite UI** (remote
   execution), not only from `run_on_vm ... dnf`.
2. **GitOps with AAP as the executor for Satellite**: a merge under
   `satellite/` is applied by an AAP job, not by an Argo CD PostSync Job.
   **VMs on OpenShift stay with Argo CD** (`rhel-fleet`).
3. The run sheet stays Markdown, and a script renders it into a **static HTML
   page** with real links and credentials filled in from the env file and the
   cluster. The rendered page is never committed.

Non-goals: replacing Argo CD for VMs; changing the Satellite/IdM install path;
moving the CLI scripts away (they stay as the fast path and the fallback).

## Principles

- **Git stays the source of truth.** AAP templates that change desired state
  open a pull request (like V3 does today); only "act now" operations
  (publish a version, incremental update, package update on a host) call
  Satellite directly, exactly as their CLI twins do.
- **One logic, two front ends.** Where a CLI script and an AAP template do the
  same thing, they share the playbook (CLI runs it through `ansible-navigator`
  with the same EE) or the CLI script is kept and the playbook mirrors it 1:1,
  tested against the same acceptance checks.
- **AAP queues, Argo CD skipped.** AAP job templates run one at a time
  (`allow_simultaneous: false`), which also removes the "merged while a Job
  runs" race from the rehearsal.

## Naming (proposal, D2)

AAP job templates, grouped by prefix so the Templates list reads like the run sheet:

| Prefix | Meaning | Templates |
|---|---|---|
| `GitOps ·` | opens a PR in Gitea (desired state) | `GitOps · Promote release`, `GitOps · Record Satellite state`, `GitOps · Roll back last release`, `GitOps · Request RHEL server` (today: "Request RHEL server"), `GitOps · Add host collection` (optional) |
| `SAT ·` | acts on Satellite | `SAT · Apply Satellite as code` (the executor), `SAT · Publish new version`, `SAT · Hotfix (incremental update)`, `SAT · Status` |
| `HOST ·` | acts on hosts through Satellite remote execution | `HOST · Update package`, `HOST · Undo last package transaction` |
| `VM ·` | acts on OpenShift directly, outside Git | `VM · Create server by hand (V1)` |
| `DEMO ·` | demo housekeeping | `DEMO · Reset to start state` (optional, D4), `DEMO · Prepare before the session` (optional) |

Run sheet: every step lists its alternatives with fixed labels:
`CLI ▸`, `AAP ▸`, `Satellite UI ▸`, `Gitea ▸`, `Console ▸`.

## CLI -> AAP mapping

| Run sheet step | CLI today | AAP template | Satellite UI / other |
|---|---|---|---|
| T-30 publish next version | `publish-version.sh <NEXT>` | `SAT · Publish new version` (survey: version; RPM built inside the EE, uploaded with `content_upload`) | Content Views -> Publish (only the CV part) |
| 1.1 promote Dev | `release.sh promote dev` | `GitOps · Promote release` (env, version optional, merge yes/no) | - |
| 1.1 / 1.3 update package | `run_on_vm lc-dev "dnf upgrade demo-app"` | `HOST · Update package` (host search, package, optional advisory) | **Hosts -> select -> Schedule remote job -> Packages -> Update** |
| 1.2 record UI promotion | `release.sh promote qa` / `record` | `GitOps · Record Satellite state` | Content Views -> Promote (the UI action itself) |
| 1.3 hotfix | `hotfix.sh <erratum> prod` | `SAT · Hotfix (incremental update)` | Content Views -> Demo-App-CV -> Versions -> Errata -> Apply |
| 1.4 rollback | `release.sh rollback` | `GitOps · Roll back last release` | - |
| 1.4 undo on host | `run_on_vm lc-prod "dnf history undo last"` | `HOST · Undo last package transaction` | Schedule remote job -> Commands -> Run command |
| 2.1 V1 by hand | `manual-vm.sh legacy-01 dev` | `VM · Create server by hand (V1)` | Console -> Create -> With YAML (documented) |
| 2.2 V2 | `new-server.sh app-dev-01 dev` | (V2 is the Git path by design) | Gitea web editor |
| 2.2 V3 | - | `GitOps · Request RHEL server` (exists) | - |
| 2.3 Satellite as code | Gitea web editor | `GitOps · Add host collection` (optional) | - |
| apply after merge | Argo CD PostSync Job | **`SAT · Apply Satellite as code`, triggered by EDA** | - |
| status | `status.sh` | `SAT · Status` | - |
| reset | `reset.sh` | `DEMO · Reset to start state` (D4) | - |

## Architecture change for Satellite as code (D1)

```
Gitea push (main) ──webhook──▶ AAP Event Stream ──▶ EDA rulebook
                                                       │ commit touches satellite/ ?
                                                       ▼
                                   job template "SAT · Apply Satellite as code"
                                   project = Gitea repo (sync on launch), EE = runner EE
                                   credentials: Satellite API, OpenShift token
                                   writes: Satellite; Secret satellite-registration and
                                   ConfigMap satellite-cac-applied via kubernetes.core
Gitea push (main) ──webhook──▶ Argo CD rhel-fleet ──▶ VirtualMachines   (unchanged)
```

- **D1 recommended: EDA** (enable EDA in the `aap` instance, Event Stream with
  a token credential, Gitea webhook with that token, rulebook in the repo under
  `aap/rulebooks/`). Most natural "GitOps with AAP" story, and job output is in AAP.
  Cost: EDA pods (~1 CPU, 2-3 GiB), one more moving part.
- Alternative B: keep the Argo CD `satellite-config` app, but its PostSync Job
  only launches the AAP template and waits (Argo still shows the result).
- Either way the old in-cluster Job path stays behind a switch
  (`SATELLITE_EXECUTOR=aap|argo`, default `aap`) as a fallback, and
  `run-local.sh` stays.

## Work packages

### P0 - Spike: verify the risky assumptions (~1 h) - DONE 2026-11-20

Results:
- **EE: GO, no Automation Hub token.** AAP 2.7's default EE
  `ee-supported-rhel9` contains `redhat.satellite` 5.13.0, `kubernetes.core`
  6.4.0, `redhat.openshift_virtualization` 2.3.0 and python `kubernetes`. An
  in-cluster Docker build `FROM` it works (cluster pull secret) and
  `rpm-build` installs from UBI repos -> one custom EE = ee-supported + rpm-build.
- **EDA: GO.** Enabled in instance `aap` (pods up in ~6 min). Event Streams
  API present; credential types include "HMAC Event Stream" (Gitea signs with
  `X-Gitea-Signature` / `X-Hub-Signature-256`) and "Basic Event Stream". No
  decision environment exists yet -> create one (de-supported-rhel9) in P2.
  The end-to-end Gitea -> event stream -> rulebook test is the first task of P2.
- **Satellite REX pull-mqtt: GO after a fix.** `yggdrasild` had exited on
  lc-prod and app-dev-00 ("cannot connect to broker ... no route to host" at
  boot, `Restart=no`) and never came back; after a restart a "Run Command"
  job succeeded on both hosts (lc-prod: demo-app-1.2). Fix in P4: systemd
  drop-in `Restart=always`, `RestartSec=30` in lc and fleet cloud-init, plus a
  one-off restart for existing hosts.
- **Kubernetes API from a job pod:** not separately tested (standard bearer-token
  credential); covered in P1.

- Log in, cluster still alive and demo in start state.
- `registry.redhat.io/ansible-automation-platform-*/ee-supported-rhel9`
  (pulled with the cluster pull secret, no Automation Hub token): does it
  contain `redhat.satellite` and `kubernetes.core`? Can an in-cluster build use
  it as a base image? If not: ask for an Automation Hub token (D3).
- EDA in AAP 2.7: Event Stream + Gitea webhook payload reaches a test rulebook.
- Satellite REX pull-mqtt works on lc-* and fleet hosts (`foreman_ygg_worker`,
  MQTT 1883 through the Satellite Service) - prerequisite for every `HOST ·`
  template and the Satellite UI package update.
- An AAP job pod can talk to the Kubernetes API with a bearer-token credential.
Exit: go/no-go per item; plan adjusted before P1.

### P1 - Execution environment, credentials, RBAC (~1.5 h) - DONE 2026-11-20

Done: runner image = ee-supported-rhel9 + rpm-build ("GitOps EE"), playbooks
on `redhat.satellite`, cluster writes via `kubernetes.core` (one path for the
Argo Job, AAP and run-local.sh), `bootstrap/aap-rbac.yaml` (SA `aap-demo`,
namespace Role, image-puller for `system:serviceaccounts:aap`), AAP
credentials "Satellite API" + "OpenShift API (demo namespace)", EE "GitOps
EE", templates `SAT · Apply Satellite as code` and `GitOps · Request RHEL
server` (old name removed). Verified: AAP job 22 successful in 83 s.

- One EE for everything (D3): `gitops/runner/Containerfile` becomes
  `FROM ee-supported-rhel9` (+ `rpm-build`, python `kubernetes` if missing).
  The same image runs AAP jobs, the Argo fallback Job and `run-local.sh`, and
  all playbooks switch from `theforeman.foreman` to `redhat.satellite`.
  Built in-cluster as today; AAP pulls it from the internal registry
  (image-puller RoleBinding for the `aap` namespace).
- ServiceAccount `aap-demo` in `satellite-cloud-native` with a Role limited to
  Secrets/ConfigMaps (registration, drift state) and VirtualMachines (V1).
- AAP config as code (`aap/aap-config.yml`): credential types "Satellite API"
  and "Gitea API" (exists), "OpenShift API Bearer Token" credential, EE, project.
- `bootstrap.sh aapconfig` creates the SA token and the credentials.

### P2 - Satellite as code executed by AAP (~2.5 h) - DONE 2026-11-20

Done and verified: EDA objects as code (credentials `aap_controller`,
`gitea_push_hmac` [HMAC, X-Hub-Signature-256, hex, prefix "sha256="], DE
`de_supported`, project `rhel_fleet`, event stream `gitea_push`, activation
`satellite_as_code`), rulebook `rulebooks/satellite-as-code.yml`, Gitea
webhook to the event stream, `SATELLITE_EXECUTOR=aap` (default) removes the
Argo CD app `satellite-config`, playbook ends early when a push changes nothing
under `satellite/`, `release.sh`/`reset.sh`/`status.sh` follow the AAP job.
Measured: PR merge -> AAP job created 7 s, done 84 s (Argo CD path ~2 min);
push without satellite/ changes -> job ends in 14 s, Satellite untouched.

- `site.yml`: write the Secret and the ConfigMap with `kubernetes.core.k8s`
  (in-cluster SA, AAP credential, or kubeconfig on the laptop: one code path
  instead of three).
- Job template `SAT · Apply Satellite as code`, `allow_simultaneous: false`.
- EDA: enable in `bootstrap/aap-instance.yaml`, event stream, rulebook
  activation, Gitea webhook (`bootstrap.sh webhook`).
- Argo CD `satellite-config` created only when `SATELLITE_EXECUTOR=argo`.
- `release.sh --merge`, `reset.sh`, `status.sh`: wait for / report the AAP job
  instead of the Kubernetes Job (through the AAP API).

### P3 - Release and content templates (~3 h) - DONE 2026-11-20

Done: `aap/promote-release.yml`, `record-state.yml`, `rollback-release.yml`,
`hotfix.yml`, `publish-version.yml`, `status.yml`, shared `aap/tasks/`
(Gitea PR, releases read) and `aap/files/demo-app.spec.j2`; templates with
surveys. Deviation: the CLI keeps its own spec in `build_and_upload_rpm`
(shared with c1 and the SOE profile); both produce the same package and the
AGENTS.md note says to change them together. `gitops/scripts/aap-run.sh`
launches any template from the terminal. Verified: whole Demo 1 through AAP.

- Playbooks in `aap/`: `promote-release.yml`, `record-state.yml`,
  `rollback-release.yml` (Gitea contents API: read, edit, branch, PR, optional
  merge with retry), `hotfix.yml` (Katello incremental-update API + task wait),
  `publish-version.yml` (build RPM in the EE from one shared spec template,
  `content_upload`, publish Demo-App-CV + composite, refuse existing versions).
- One shared demo-app spec template used by both `build_and_upload_rpm` (CLI)
  and `publish-version.yml`.
- CLI scripts keep their behaviour; acceptance checks are run on both paths.

### P4 - Host and VM templates, Satellite UI path (~1.5 h) - DONE 2026-11-20 (UI clicks documented in P5)

Done: `HOST · Update package` (update or one erratum), `HOST · Undo last
package transaction` (Satellite REX, pull-mqtt), `VM · Create server by hand
(V1)`; yggdrasild `Restart=always` drop-in in lc and fleet cloud-init and on
the running hosts. Verified on lc-dev, lc-qa, lc-prod; V1 VM created in 12 s.

- `HOST · Update package`, `HOST · Undo last package transaction`:
  `job_invocation` through Satellite (pull-mqtt), wait for the result.
- Satellite UI steps for the same actions documented with exact clicks.
- `VM · Create server by hand (V1)`: renders `templates/vm.yaml.j2` with
  `provisioned_by=manual` and applies it with `kubernetes.core.k8s`.
- Console "Create from template" snippets (`templates/console-snippets.md`).

### P5 - Run sheet and static page (~2 h) - DONE 2026-11-20

Done: `gitops/README.md` rewritten (architecture with AAP/EDA, template table
with CLI twins, run sheet with `CLI ▸ / AAP ▸ / Satellite UI ▸ / Gitea ▸ /
Console ▸` per step, `{{placeholders}}`, fallbacks, tear-down);
`gitops/scripts/render-runsheet.sh` + `render_runsheet.py` (stdlib only,
offline, CSP, secrets masked with show/copy, file mode 0600, refuses to write
into the work tree unless the name is gitignored); `.gitignore` covers
`*.local.html` and `runsheet*.html`. Satellite UI path "Select Action ->
Schedule Remote Job" checked on the live UI.

- Restructure `gitops/README.md`: per step the alternatives `CLI ▸ / AAP ▸ /
  Satellite UI ▸`, with timings for each path.
- Placeholders in the Markdown: `{{SAT_URL}}`, `{{GITEA_URL}}`, `{{AAP_URL}}`,
  `{{ARGOCD_URL}}`, `{{CONSOLE_URL}}`, `{{LC_DEV_URL}}`..`{{LC_PROD_URL}}`,
  `{{DEMO_PASSWORD}}`, `{{AAP_PASSWORD}}`, `{{NEXT_VERSION}}`.
- `gitops/scripts/render-runsheet.sh`: reads `DEMO_ENV_FILE`, routes (`oc`),
  `~/.cache/satellite-demo/*` (AAP password, next version from Satellite),
  renders one self-contained offline HTML file (dark Red Hat style, copy
  buttons for commands, credentials hidden behind a "show" toggle).
- Output by default **outside the repo** (`~/.cache/satellite-demo/runsheet.html`);
  `.gitignore` also covers `*.local.html` and `runsheet*.html` in case it is
  rendered into the tree. Renderer: python3 stdlib only (no new dependency).

### P6 - Verification (~2.5 h) - DONE 2026-11-20

Done: whole Demo 1 through AAP (me), independent code review (0 blockers, 10
risks - all fixed), fresh-eyes rehearsal of the new run sheet by a subagent
(T-30, Demo 1, Demo 2; all 11 templates worked, two launched through the AAP
web UI, package update through the Satellite UI job wizard; doc fixes applied),
new reset.sh tested (full apply launched and awaited), narrowed RBAC verified
(`can-i get secret/rhsm-credentials` = no), Argo CD fallback executor
exercised and switched back, run-local.sh not re-run (needs `podman login
registry.redhat.io` on the laptop). Not done: `DEMO · Reset` template (D4,
optional; `reset.sh` stays the reset path).

- Demo 1 and Demo 2 end to end through the AAP path, then a CLI regression run.
- Independent verifier subagent per demo (acceptance criteria 1-12, plus: each
  CLI step has a working AAP twin; package update works from the Satellite UI).
- Fresh-eyes rehearsal of the new run sheet using the rendered HTML page.
- `reset.sh` (and `DEMO · Reset`, if D4) back to the start state.
- AGENTS.md gotchas; diff summary; commit only after approval.

Total estimate: **~14 h**, i.e. two working sessions. P0 decides whether the
EDA and Satellite-REX parts go ahead as planned.

## Decisions

- **D1 EDA** - Gitea webhook -> AAP Event Stream -> rulebook -> `SAT · Apply Satellite as code`.
- **D2 prefixes** as proposed (`GitOps ·`, `SAT ·`, `HOST ·`, `VM ·`, `DEMO ·`).
- **D3 `redhat.satellite`** - from the supported EE; Automation Hub token only if P0 shows it is needed.
- **D4** `DEMO · Reset to start state` as an optional last item (CLI `reset.sh` stays).
- **D5** baseline commit of the rehearsed state before P0 (no push).

## Risks

| Risk | Mitigation |
|---|---|
| EDA event stream / Gitea payload not compatible | P0 spike; fallback D1-B (Argo hook launching AAP) |
| REX pull-mqtt not working on lc-* hosts | P0 spike; fix registration (`setup_remote_execution_pull`) or keep `run_on_vm` for those steps |
| EE build and pull across namespaces | image-puller RoleBinding; fallback: Galaxy `collections/requirements.yml` in the project |
| In-cluster build cannot pull `ee-supported` from registry.redhat.io | link a registry.redhat.io pull secret to the builder SA (owner provides/approves), or an Automation Hub token for `redhat.satellite` |
| Cluster capacity with EDA | measured before (≈123 GiB free); EDA ≈ 3 GiB |
| Lab cluster expiry | check RHDP end date before starting; everything re-deployable with bootstrap |
