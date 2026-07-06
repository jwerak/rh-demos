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

### Krok 4: Scénář A — Standardní objednávka VM (Phase B)

MR-based approval: template vytvoří MR v GitLabu → owner schválí → security schválí → merge → ArgoCD sync → VM.

- [ ] Upravit Create VM template — `publish:gitlab` + `publish:gitlab:merge-request`
- [ ] GitLab approval rules — `vm-instances` group: 2 approvals (app-owners + security-admins)
- [ ] Protected branch `main` — no direct push, MR required
- [ ] Post-provisioning: ServiceMonitor, OADP Schedule v skeleton manifests
- [ ] CMDB: catalog-info.yaml + RHDH catalog annotations

### Krok 5: Scénář B — Požadavek porušující politiku (Phase B)

Gatekeeper OPA policies blokují VM které porušují naming/limity/labely.

- [ ] Deploy Gatekeeper (`gatekeeper-operator-product`)
- [ ] ConstraintTemplates: naming convention, resource limits, required labels
- [ ] Policy violation → ArgoCD SyncFailed → viditelné v RHDH
- [ ] Exception workflow: oprava přes nový MR → approval → sync

### Krok 6: Scénář C — Změna existující služby (Phase B)

"Resize VM" template: MR se změnou CPU/RAM → approval → ArgoCD sync.

- [ ] Nová šablona `templates/resize-vm/`
- [ ] Quota validace v šabloně
- [ ] MR diff ukazuje staré → nové hodnoty
- [ ] Audit trail v Git historii

### Krok 7: Scénář D — Vyřazení služby (Phase B)

"Decommission VM" template: smaže manifesty → approval → ArgoCD prune → CMDB cleanup.

- [ ] Nová šablona `templates/decommission-vm/`
- [ ] Backup check před smazáním
- [ ] GitLab repo archivace
- [ ] RHDH catalog entity removal

### Krok 8: SonataFlow Orchestrator (Phase C — optional)

Enterprise workflow engine jako enhancement nad MR-based approval.

- [ ] Install Serverless + SonataFlow operators
- [ ] SonataFlowPlatform + Data Index
- [ ] Approval workflow (owner → security → provision)
- [ ] RHDH Orchestrator plugin UI
