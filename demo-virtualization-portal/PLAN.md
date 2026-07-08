# Plan: demo-virtualization-portal

Self-service VM portál pro PTK 2. kolo — RHDH 1.10 + GitLab + ArgoCD + OCP Virt.

## Rozhodnutí

- Portál: RHDH 1.10 (Operator)
- Auth: guest login (Phase A), Keycloak OIDC (Phase B/C)
- Git: GitLab CE na clusteru (nativní podpora v RHDH — `integrations.gitlab`, `publish:gitlab`)
- GitOps: OpenShift GitOps (ArgoCD) od nuly
- Workflow: RHDH Orchestrator / SonataFlow (Phase B)
- VM: OCP Virtualization (už na clusteru)
- CMDB: Netbox (Phase C)
- Backup: OADP + MinIO (Phase C)
- Bez AAP — vše Kubernetes-native přes GitOps

### Proč GitLab místo Gitea

Gitea NENÍ podporovaná v RHDH 1.10. `integrations.gitea` neexistuje, GitHub URL reader nedokáže
parsovat Gitea raw URL formát (`/raw/branch/{ref}/` vs GitHub's `/raw/{ref}/`). Pokusy o workaround
(internal URL, backend.reading.allow, dual GitHub integration) selhaly na `fetch:template` akci
scaffolderu, která vyžaduje funkční integration pro čtení skeleton souborů.

GitLab je first-class citizen v RHDH:
- `integrations.gitlab` — nativní integrace s PAT tokenem
- `publish:gitlab` — scaffolder akce pro vytváření repozitářů
- `catalog-backend-module-gitlab` — auto-discovery entit z GitLab skupin
- Plně testováno a supportováno Red Hatem

## Architektura: dva Git servery

- **GitHub** (rh-demos repo): ArgoCD čte infrastrukturní manifesty
- **GitLab** (on-cluster): RHDH šablony/katalog + scaffolded VM repos

## Adresářová struktura

```
demo-virtualization-portal/
├── CLAUDE.md
├── .env.sample
├── bootstrap/                          # deploy.sh Phase 1: oc apply -k bootstrap/
│   ├── kustomization.yaml
│   ├── 01-gitops-subscription.yaml     # OpenShift GitOps Operator
│   └── 02-argocd-rbac.yaml            # ClusterRole + Binding
├── argocd-apps/                        # deploy.sh aplikuje sekvenčně
│   ├── phase1-operators.yaml           # → base/operators/
│   ├── phase2-instances.yaml           # → base/gitlab/ + base/rhdh/
│   └── phase3-demo-env.yaml           # → base/demo-env/
├── base/
│   ├── operators/                      # RHDH Operator Subscription
│   ├── gitlab/                         # GitLab CE Deployment, Service, Route, PVCs
│   ├── rhdh/                           # Backstage CR, app-config, dynamic-plugins
│   └── demo-env/                       # Namespaces, Quotas, NetworkPolicies
├── templates/
│   ├── catalog-info.yaml               # Backstage Location
│   └── create-vm/
│       ├── template.yaml               # scaffolder.backstage.io/v1beta3
│       └── skeleton/                   # Nunjucks-templated VM manifests
│           ├── catalog-info.yaml
│           └── vm-manifests/
│               ├── kustomization.yaml
│               ├── virtualmachine.yaml
│               ├── service.yaml
│               └── cloudinit-secret.yaml
├── scripts/
│   ├── deploy.sh                       # Phased deployment (0-6)
│   ├── seed-gitlab.sh                  # GitLab API: groups, projects, push templates
│   ├── create-demo-users.sh            # htpasswd users
│   └── teardown.sh
└── docs/
    └── mkdocs.yml
```

## VM Ordering GitOps Loop

```
User → RHDH Template → publish:gitlab → GitLab repo (vm-instances/<vm-name>)
                                              ↓
ArgoCD SCM Provider (watches vm-instances group) → discovers new repo
                                              ↓
ArgoCD syncs VirtualMachine CR → OCP Virt creates VM
```

## Co je už hotové a co je třeba změnit

### Soubory, které ZŮSTÁVAJÍ beze změn
- `bootstrap/` — GitOps Operator + RBAC (OK)
- `base/operators/` — RHDH Operator Subscription (OK)
- `base/demo-env/` — Namespaces, Quotas, NetworkPolicies (OK)
- `argocd-apps/phase1-operators.yaml` — (OK)
- `argocd-apps/phase3-demo-env.yaml` — (OK)
- `templates/create-vm/skeleton/vm-manifests/` — VirtualMachine CR, Service, CloudInit (OK)

### Soubory, které je třeba SMAZAT (Gitea-specific)
- `base/gitea/` — celý adresář (nahrazeno base/gitlab/)
- `scripts/seed-gitea.sh` — nahrazeno seed-gitlab.sh

### Soubory, které je třeba VYTVOŘIT
- `base/gitlab/namespace.yaml` — Namespace gitlab
- `base/gitlab/pvc.yaml` — PVCs pro GitLab (config, data, logs)
- `base/gitlab/deployment.yaml` — gitlab/gitlab-ce:latest, env vars pro EXTERNAL_URL, root password
- `base/gitlab/service.yaml` — ClusterIP port 80 (GitLab HTTP), 22 (SSH)
- `base/gitlab/route.yaml` — TLS edge, `gitlab.__BASE_DOMAIN__`
- `base/gitlab/kustomization.yaml`
- `scripts/seed-gitlab.sh` — GitLab API: create groups (demo, vm-instances), push templates

### Soubory, které je třeba UPRAVIT
- `.env.sample` — Gitea → GitLab (GITLAB_ADMIN_PASSWORD, GITLAB_TOKEN místo GITEA_*)
- `CLAUDE.md` — Gitea → GitLab references
- `base/rhdh/app-config-cm.yaml` — `integrations.gitlab` místo `integrations.github`, `catalog.locations` → GitLab URL
- `base/rhdh/dynamic-plugins-cm.yaml` — enable `backstage-plugin-catalog-backend-module-gitlab-org-dynamic`
- `base/rhdh/secrets.yaml` — GITLAB_TOKEN místo GITEA_TOKEN
- `base/rhdh/backstage-cr.yaml` — zachovat NODE_TLS_REJECT_UNAUTHORIZED=0
- `argocd-apps/phase2-instances.yaml` — base/gitea → base/gitlab
- `templates/create-vm/template.yaml` — `publish:gitlab` místo `publish:github`, repoUrl format pro GitLab
- `templates/create-vm/skeleton/catalog-info.yaml` — GitLab URL v anotacích
- `templates/catalog-info.yaml` — GitLab URL
- `scripts/deploy.sh` — Gitea → GitLab (admin user creation, env vars, wait conditions)
- `scripts/teardown.sh` — gitea namespace → gitlab namespace

## RHDH app-config pro GitLab

```yaml
integrations:
  gitlab:
    - host: gitlab.__BASE_DOMAIN__
      token: ${GITLAB_TOKEN}

catalog:
  locations:
    - type: url
      target: https://gitlab.__BASE_DOMAIN__/demo/templates/-/raw/main/catalog-info.yaml
      rules:
        - allow: [Location, Template]

# dynamic-plugins.yaml — optional, for auto-discovery:
plugins:
  - package: ./dynamic-plugins/dist/backstage-plugin-catalog-backend-module-gitlab-org-dynamic
    disabled: false
```

## Template: publish:gitlab

```yaml
- id: publish
  name: Publish to GitLab
  action: publish:gitlab
  input:
    repoUrl: gitlab.__BASE_DOMAIN__?owner=vm-instances&repo=${{ parameters.vmName }}
    defaultBranch: main
    repoVisibility: public
```

## GitLab CE Deployment Notes

- Image: `gitlab/gitlab-ce:latest`
- GitLab needs significant resources: min 4Gi RAM, 2 CPU
- First boot takes 3-5 minutes (database migration)
- Root password set via `GITLAB_ROOT_PASSWORD` env var
- External URL set via `GITLAB_OMNIBUS_CONFIG` env var
- PVCs: /etc/gitlab (config, 1Gi), /var/opt/gitlab (data, 10Gi), /var/log/gitlab (logs, 2Gi)
- GitLab exposes HTTP on port 80 (not 443 — TLS terminated at Route)
- API token created via: `gitlab-rails runner "token = User.find_by_username('root').personal_access_tokens.create(scopes: ['api'], name: 'rhdh', expires_at: 365.days.from_now); token.set_token('glpat-xxxx'); token.save!"`

## DNS Setup

Wildcard A record: `*.<base-domain>` → router IP.
To find the router IP:
```bash
dig +short console-openshift-console.$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
```
NOTE: Do NOT use CNAME to apps.<cluster> — the bare apps domain has no A record.

## Known Issues from Phase A (Gitea attempt)

1. OpenShift OAuth is NOT OIDC — needs Keycloak broker (Phase B/C)
2. RHDH Operator auto-generates Route hostname — must patch after each restart
3. NODE_TLS_REJECT_UNAUTHORIZED=0 needed when custom domain doesn't match Router cert
4. Dynamic plugin package names need `-dynamic` suffix
5. `auth.providers.guest.dangerouslyAllowOutsideDevelopment: true` needed for guest auth to actually work

## Implementační kroky

### Krok 1: Migrace Gitea → GitLab ✅ HOTOVO (2026-07-05)

1. ✅ Smazat `base/gitea/` adresář a `scripts/seed-gitea.sh`
2. ✅ Vytvořit `base/gitlab/` manifesty (namespace, scc, deployment, service, route, PVCs, kustomization)
3. ✅ Vytvořit `scripts/seed-gitlab.sh` (GitLab API: PAT via rails runner, groups, projects, push templates)
4. ✅ Aktualizovat `base/rhdh/` (app-config s integrations.gitlab + apiBaseUrl/baseUrl, dynamic-plugins se scaffolder-backend-module-gitlab, secrets)
5. ✅ Aktualizovat templates (publish:gitlab, GitLab URLs s /-/blob/ formátem)
6. ✅ Aktualizovat skripty (deploy.sh — přímý apply místo ArgoCD pro gitlab/rhdh, teardown.sh)
7. ✅ Aktualizovat meta soubory (.env.sample, .env, CLAUDE.md), smazat phase2-instances.yaml

Poučení z implementace:
- GitLab CE 18.11.6 (ne 17.x — nelze přeskočit major verze při upgrade)
- `gitlab_rails['monitoring_whitelist'] = ['0.0.0.0/0']` nutný pro K8s health probes
- RHDH vyžaduje `apiBaseUrl` a `baseUrl` v integrations.gitlab (ne jen host+token)
- `publish:gitlab` nepodporuje `allowedHosts` ani `description` (na rozdíl od publish:github)
- Catalog location URL musí použít `/-/blob/` ne `/-/raw/`
- GitLab protected branch blokuje force push — seed skript musí unprotect před pushem
- Anyuid SCC binding nutný pro GitLab CE (běží jako root)

### Krok 2: Deploy a validace na clusteru ✅ HOTOVO (2026-07-05)

```bash
cp .env.sample .env  # Edit with your values
source .env
./scripts/deploy.sh
```

Validační checklist:
- [x] GitLab UI se načte a login funguje (root / password)
- [x] RHDH UI se načte, guest login funguje
- [x] "Create VM" šablona je viditelná v RHDH katalogu (Kind: Template)
- [x] Vytvořit VM přes šablonu → repo se objeví v GitLab pod vm-instances skupinou
- [x] ArgoCD vytvoří Application pro nový repo (ApplicationSet s GitLab SCM Provider — `argocd-apps/vm-instances-appset.yaml`)
- [x] `oc get vm -n vm-dev` — VM běží (test-vm-01: Running/Ready)

### Krok 3: Auth + RBAC (Phase B) ✅ HOTOVO (2026-07-06)

Keycloak + RHDH OIDC + RBAC → demo users s různými rolemi.

- [x] Deploy Keycloak (dev mode) — `base/keycloak/` (namespace, realm-cm, deployment, service, route)
- [x] Demo users: vm-requestor, app-owner, security-admin, platform-admin (groups: requestors, app-owners, security-admins, platform-admins)
- [x] RHDH OIDC — `auth.providers.oidc` s `additionalScopes: [groups]`, `signInPage: oidc`, Keycloak user provisioning via `catalog.providers.keycloakOrg`
- [x] RBAC — `permission.enabled: true`, frontend RBAC plugin enabled
- [x] `scripts/configure-keycloak.sh` — post-import script pro OIDC scopes + service account roles (nutné protože dev mode H2 ztrácí API změny při restartu)

Poučení z implementace:
- Keycloak realm import NEVYTVÁŘÍ built-in scopes (openid, profile, email) — nutno vytvořit via admin API po startu
- RHDH 1.10 OIDC provider používá `additionalScopes` ne `scope` (breaking change)
- Service account klienta potřebuje `realm-management` role (view-users, view-realm, query-groups, query-users) pro Keycloak catalog provider
- Keycloak dev mode (`start-dev`) ztrácí data při restartu podu — `configure-keycloak.sh` musí běžet po každém restartu
- RBAC deny-by-default: `scaffolder-action` permission nutný pro `fetch:template`, `publish:gitlab` atd.
- RBAC: `catalog.entity.create` + `catalog.location.create` nutné pro `catalog:register` akci
- RBAC frontend plugin (`backstage-community-plugin-rbac`) je jen UI, backend je built-in v RHDH 1.10
- ArgoCD ApplicationSet controller musí být explicitně povolen v ArgoCD CR (`spec.applicationSet`)
- ArgoCD RBAC: `scopes: [groups,name]` nutné pro mapování uživatelů (ne jen skupin)

### Krok 4: Scénář A — Standardní objednávka VM (Phase B) ✅ HOTOVO (2026-07-06)

MR-based approval: template vytvoří MR v GitLabu → owner schválí → security schválí → merge → ArgoCD sync → VM.

- [x] Upravit Create VM template — `publish:gitlab` + `publish:gitlab:merge-request`
- [x] GitLab approval rules — `vm-instances` group: 2 approvals (app-owners + security-admins)
- [x] Protected branch `main` — no direct push, MR required
- [x] Post-provisioning v skeleton manifests:
  - [x] CMDB: catalog-info.yaml s annotations (owner, env, created, cost-center) → RHDH katalog = CMDB
  - [x] DNS: cloud-init hostname + Service (SSH) — již v skeleton, ověřeno
  - [x] Monitoring: `ServiceMonitor` CR v `vm-manifests/`
  - [x] Backup: `VirtualMachineSnapshot` CR v `vm-manifests/`

Poučení z implementace:
- Skeleton rozdělen na `skeleton-init/` (catalog-info → main) a `skeleton-vm/` (vm-manifests → MR branch)
- `publish:gitlab` vždy pushuje na `defaultBranch` — proto split skeleton pattern
- `publish:gitlab:merge-request` vytvoří branch z main a otevře MR — ArgoCD sync až po merge
- GitLab users (app-owner, security-admin) vytváří `seed-gitlab.sh` s Maintainer rolí v `vm-instances` skupině
- `costCenter` parametr přidán pro chargeback/billing (CC-001..CC-003, CC-SHARED)
- CMDB anotace v catalog-info.yaml: `virt-portal/cost-center`, `virt-portal/environment`, `virt-portal/cpu-cores` atd.

### Krok 5: Scénář B — Požadavek porušující politiku (Phase B) ✅ HOTOVO (2026-07-06)

Gatekeeper OPA policies blokují VM které porušují naming/limity/labely.

- [x] Deploy Gatekeeper (`gatekeeper-operator-product` v3.21.0)
- [x] ConstraintTemplates + Constraints:
  - [x] Naming convention: VM name musí matchovat `^[a-z]{2,4}-[a-z]+-[0-9]{2}$`
  - [x] Resource limits: max 8 CPU, 16 GiB RAM, 100 GiB disk
  - [x] Required labels: `app.kubernetes.io/managed-by`, `environment`, `cost-center`
- [x] Separátní šablona "Create VM (Policy Test)" s volnou validací pro demo policy violations
- [x] Policy violation → ArgoCD SyncFailed → viditelné v ArgoCD UI (všech 7 violations najednou)
- [x] Audit: Gatekeeper audit controller flaguje existující non-compliant VMs
- [x] deploy.sh Phase 7: operator → Gatekeeper CR → ConstraintTemplates → Constraints

Poučení z implementace:
- ConstraintTemplate `metadata.name` MUSÍ být lowercase verze CRD `kind` (vmnamingconvention, ne vmnaminconvention)
- ConstraintTemplates musí být established (CRD vytvořeno) PŘED aplikací Constraints — nelze `oc apply -k` vše najednou
- Gatekeeper admission webhook vyhodnocuje ALL violations najednou (ne jen první) — skvělé pro demo
- Gatekeeper audit controller (interval 60s) flaguje existující non-compliant VMs bez jejich blokování
- Secret a Service projdou i když VirtualMachine je denied — Gatekeeper cílí pouze na VirtualMachine kind
- Rego `trim_suffix`/`to_number` pro parsování Kubernetes quantity stringů (e.g. "4Gi" → 4)
- Disk limit check funguje pouze s `dataVolumeTemplates` (ne `emptyDisk`) — to je OK, reálné VM vždy používají dataVolumeTemplates
- Policy-test šablona používá single skeleton + `publish:gitlab` (direct to main, no MR) pro okamžitý ArgoCD sync
- Nunjucks `{%- if values.includeLabels %}` v skeleton YAML pro conditional labels — funguje v Backstage `fetch:template`

### Krok 6: Scénář C — Změna existující služby (Phase B) ✅ HOTOVO (2026-07-07)

"Resize VM" template: MR se změnou CPU/RAM/disk → approval → ArgoCD sync.

- [x] Nová šablona `templates/resize-vm/template.yaml` (2 kroky: fetch:template + publish:gitlab:merge-request)
  - [x] Parametry: vmName, environment, osImage, cpuCores, memoryGi, diskSizeGi, owner, costCenter
  - [x] Skeleton regeneruje catalog-info.yaml + virtualmachine.yaml s novými hodnotami
- [x] MR diff ukazuje staré → nové hodnoty → approval → merge
- [x] Audit trail v Git historii + RHDH catalog update (virt-portal/* anotace)
- [x] Entity page link: "Resize VM" odkaz na stránce VM entity v RHDH

Poučení z implementace:
- Backstage scaffolder nemůže fetch/patch existující soubory z remote repo — nutno regenerovat celé soubory ze skeleton
- `publish:gitlab:merge-request` používá GitLab Commits API s file-level `update` — soubory mimo workspace zůstávají nedotčeny
- `commitAction: update` NUTNÝ v template — bez něj plugin defaultuje na `auto` režim, který nejprve listuje soubory přes Gitbeaker; pokud listing selže (fetch failed), fallback na `create` akci, která failne na existujících souborech
- Všechny parametry (včetně environment, osImage, owner) jsou povinné, protože skeleton regeneruje celé soubory
- Entity page link (`/create/templates/default/resize-vm`) přidán do catalog-info.yaml skeleton pro přístup z VM detail page
- Quota validace přesunuta do Gatekeeper policies (automaticky validuje při ArgoCD sync)
- `integrations.gitlab[host=svc].baseUrl` MUSÍ být `http://gitlab.gitlab.svc.cluster.local` (ne externí HTTPS URL) — Backstage plugin GitLab scaffolder používá `baseUrl` (ne `apiBaseUrl`) pro inicializaci Gitbeaker klienta, a RHDH pod nedosáhne na externí URL
- Po merge MR je nutný ArgoCD refresh (`argocd.argoproj.io/refresh=hard`) nebo počkat na polling interval
- Template output `mergeRequestUrl` se neresolvuje (Gitbeaker checkpoint issue) — MR URL je ale správně viditelná v GitLab
- Entity page link používá `formData` query parametr pro pre-fill všech hodnot (vmName, environment, osImage, cpuCores, memoryGi, diskSizeGi, costCenter)
- Backstage entity links vyžadují absolutní URL — relativní cesty (`/create/...`) failnou na validaci

**✅ FIXED — CPU/RAM hotplug pro live resize bez restartu (2026-07-08):**
- Příčina: `cpu.cores` a `resources.requests.memory` jsou "non-live-updatable" fields — KubeVirt nastaví `RestartRequired: True`
- Řešení: VM manifesty přepracovány pro KubeVirt hotplug API:
  - CPU: `cpu.cores` → `cpu.sockets` + `cores: 1` + `threads: 1` + `maxSockets: 8`
  - RAM: `resources.requests.memory` → `domain.memory.guest` (KubeVirt automaticky počítá pod resources)
  - Změna `sockets` nebo `memory.guest` triggeruje live migration → hotplug bez restartu
- Gatekeeper ConstraintTemplate `vmresourcelimits` aktualizován: `cpu.cores` → `cpu.sockets`, `resources.requests.memory` → `domain.memory.guest`
- Resize template: `environment` a `osImage` pole nastaveny jako `ui:disabled: true` (nelze měnit při resize)
- ✅ FIXED: `LiveMigratable: False (DisksNotLiveMigratable)` — všechny skeleton templates opraveny z `ReadWriteOnce` → `ReadWriteMany` (Ceph RBD podporuje RWX v Block mode)
- Nově vytvořené VM budou live-migratable; existující VM (`dev-web-01`) vyžaduje re-provisioning (smazat a vytvořit znovu přes šablonu)
- Prerekvizity na clusteru: `vmRolloutStrategy: LiveUpdate` a `workloadUpdateMethods: [LiveMigrate]` v KubeVirt/HyperConverged CR (GA od OCP Virt 4.17, mělo by být defaultně zapnuto)
- Disk resize nefunguje: když se v Gitu zvětší `diskSizeGi` a ArgoCD syncne nový manifest, PVC velikost se nezvětší — Kubernetes PVC `spec.resources.requests.storage` je immutable po vytvoření, zvětšení vyžaduje volume expansion request přes `status` nebo ruční resize

### Krok 7: Scénář D — Vyřazení služby (Phase B)

"Decommission VM" template: smaže manifesty → approval → ArgoCD prune → cleanup.

- [ ] Nová šablona `templates/decommission-vm/template.yaml`
  - [ ] Parametry: vmName (picker), reason, confirmBackup (checkbox)
  - [ ] Verify backup exists (VirtualMachineSnapshot check)
- [ ] MR smaže manifesty z repo → approval → merge → ArgoCD prune
- [ ] GitLab repo archivace (read-only)
- [ ] RHDH catalog entity removal

### Krok 8: Blueprinty / šablony služeb (Phase B)

PTK téma: vytvoření nové šablony, změna existující, verzování, publikace.

- [ ] Přidat další šablony do katalogu:
  - [ ] "Create VM" (existuje), "Resize VM" (krok 6), "Decommission VM" (krok 7)
  - [ ] "Create Database VM" — varianta s PostgreSQL/MySQL pre-configured
- [ ] Verzování šablon: Git tags v `demo/templates` repo, catalog odkaz na konkrétní verzi
- [ ] Správce šablon: platform-admin může editovat šablony přes GitLab, RHDH automaticky refreshne
- [ ] `templates/catalog-info.yaml` — Location odkazující na všechny šablony

### Krok 9: Oddělení uživatelů, týmů a aplikací (Phase B)

PTK téma: tenant model, viditelnost omezená na vlastní zdroje.

- [ ] RHDH RBAC conditional policies: `IS_ENTITY_OWNER` — uživatel vidí jen vlastní entity
- [ ] Keycloak skupiny mapované na RHDH ownership: requestors → requestor-owned VMs
- [ ] OCP namespaces per team: vm-dev-team-a, vm-dev-team-b (volitelně)
- [ ] GitLab subgroups per team v `vm-instances/` (vm-instances/team-a/, vm-instances/team-b/)

### Krok 10: Kvóty a limity zdrojů (Phase B)

PTK téma: limity na vCPU/RAM/storage/počet VM, vynucování, workflow navyšování.

- [ ] ResourceQuota per namespace (vm-dev, vm-staging, vm-prod) — již existuje, rozšířit
- [ ] LimitRange pro VMs: min/max CPU, RAM per VM
- [ ] Gatekeeper constraint: max počet VM per team/namespace
- [ ] "Request Quota Increase" šablona — MR do `base/demo-env/quotas.yaml` → approval
- [ ] Template validace: check zda nový VM překročí kvótu před submitem

### Krok 11: Návaznost na IaC (Phase B)

PTK téma: Terraform, Ansible, API. Vazba portál → blueprint → definice v kódu.

- [ ] Demonstrace stávajícího GitOps flow: RHDH template → Git repo → ArgoCD → K8s resources
- [ ] Ansible integration: přidat AAP Job Template volání do post-provisioning (volitelně)
- [ ] API přístup: RHDH Scaffolder API endpoint pro programatické vytváření VM
  - [ ] `curl -X POST .../api/scaffolder/v2/tasks` s parametry
- [ ] Custom blueprint: ukázat jak vytvořit novou šablonu od nuly a publikovat do katalogu

### Krok 12: Návaznost na CORE a EDGE (Phase B)

PTK téma: nasazování do CORE a EDGE lokalit.

- [ ] Multi-cluster ArgoCD: environment parameter v šabloně (core/edge)
- [ ] ACM integration (volitelně): Placement + ManagedClusterSet pro edge clustery
- [ ] Demo: vytvořit VM s environment=vm-prod (CORE) vs dedicated edge namespace
- [ ] Slide: architektura ACM hub → managed clusters (CORE + EDGE)

### Krok 13: Architektura portálu — prezentace (Phase B)

PTK požadavek: vysvětlit architekturu minimálně v rozsahu:

| Komponenta | Implementace | Status |
|---|---|---|
| Komponenty portálu | RHDH (Backstage) + Keycloak + GitLab + ArgoCD | ✅ |
| Workflow engine | GitLab MR approval (Phase B), SonataFlow (Phase C) | ⏳ |
| Katalog služeb | RHDH Software Catalog | ✅ |
| API vrstva | RHDH REST API (Catalog, Scaffolder, Permission) | ✅ |
| Integrační konektory | GitLab integration, Keycloak provider, ArgoCD plugin | ✅ |
| IaC repozitáře | GitLab `vm-instances/` group, ArgoCD ApplicationSet | ✅ |
| CI/CD pipeline | ArgoCD GitOps sync (continuous delivery) | ✅ |
| Policy-as-Code | Gatekeeper OPA ConstraintTemplates | ⏳ krok 5 |
| Secret/Vault | K8s Secrets + Keycloak credentials | ✅ |
| Monitoring a logging | OCP built-in (Prometheus, Loki) + ServiceMonitor | ⏳ krok 4 |
| Databáze portálu | RHDH PostgreSQL (local DB), Keycloak H2 (dev) | ✅ |
| HA režim portálu | RHDH: multiple replicas, Keycloak: single (demo) | slide |
| Zálohování portálu | OADP (already on cluster) | slide |
| DR portálu | GitOps-based rebuild from Git repos | slide |
| Správa šablon | GitLab `demo/templates` repo, RHDH auto-discovery | ✅ |
| Správa verzí | Git versioning, GitLab tags | ⏳ krok 8 |
| Auditní úložiště | Git history + Gatekeeper audit + OCP audit logs | ⏳ krok 5 |
| Dostupnost 99%, RTO/RPO 24-48h | OCP HA + OADP backup + GitOps rebuild | slide |

### Krok 14: SonataFlow Orchestrator (Phase C — optional)

Enterprise workflow engine jako enhancement nad MR-based approval.

- [ ] Install Serverless + SonataFlow operators
- [ ] SonataFlowPlatform + Data Index
- [ ] Approval workflow (owner → security → provision)
- [ ] RHDH Orchestrator plugin UI
