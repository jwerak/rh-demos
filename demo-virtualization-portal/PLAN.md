# Plan: demo-virtualization-portal

Self-service VM portál pro PTK 2. kolo — RHDH 1.10 + Gitea + ArgoCD + OCP Virt.

## Rozhodnutí

- Portál: RHDH 1.10 (Operator)
- Auth: htpasswd → guest login (Phase A), OCP OAuth OIDC (Phase B/C)
- Git: Gitea na clusteru (GitHub-compatible API)
- GitOps: OpenShift GitOps (ArgoCD) od nuly
- Workflow: RHDH Orchestrator / SonataFlow (Phase B)
- VM: OCP Virtualization (už na clusteru)
- CMDB: Netbox (Phase C)
- Backup: OADP + MinIO (Phase C)
- Bez AAP — vše Kubernetes-native přes GitOps

## Architektura: dva Git servery

- **GitHub** (rh-demos repo): ArgoCD čte infrastrukturní manifesty
- **Gitea** (on-cluster): RHDH šablony/katalog + scaffolded VM repos

## Adresářová struktura

```
demo-virtualization-portal/
├── CLAUDE.md
├── .env.sample
├── bootstrap/                          # Ruční: oc apply -k bootstrap/
│   ├── kustomization.yaml
│   ├── 01-gitops-subscription.yaml     # OpenShift GitOps Operator
│   └── 02-argocd-rbac.yaml            # ClusterRole + Binding
├── argocd-apps/                        # deploy.sh aplikuje sekvenčně
│   ├── phase1-operators.yaml           # → base/operators/
│   ├── phase2-instances.yaml           # → base/gitea/ + base/rhdh/
│   └── phase3-demo-env.yaml           # → base/demo-env/
├── base/
│   ├── operators/                      # RHDH Operator Subscription
│   ├── gitea/                          # Deployment, Service, Route, PVC
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
│   ├── deploy.sh                       # Phased deployment
│   ├── seed-gitea.sh                   # Gitea API: orgs, repos, push templates
│   ├── create-demo-users.sh            # htpasswd users
│   └── teardown.sh
└── docs/
    └── mkdocs.yml
```

## VM Ordering GitOps Loop

```
User → RHDH Template → publish:github → Gitea repo (vm-instances/<vm-name>)
                                              ↓
ArgoCD SCM Provider (watches vm-instances org) → discovers new repo
                                              ↓
ArgoCD syncs VirtualMachine CR → OCP Virt creates VM
```

## Implementační kroky

### Krok 1: Offline příprava (BEZ clusteru)

Tyto soubory se dají připravit kompletně bez přístupu ke clusteru:

**1a. Scaffold — CLAUDE.md + .env.sample**
- `CLAUDE.md` s popisem komponent, adresářovou strukturou, key commands
- `.env.sample` s placeholdery (BASE_DOMAIN, GITEA_ADMIN_PASSWORD, BACKEND_SECRET, DEMO_PASSWORD)

**1b. Bootstrap manifesty**
- `bootstrap/01-gitops-subscription.yaml` — OpenShift GitOps Operator Subscription (channel: latest, redhat-operators)
- `bootstrap/02-argocd-rbac.yaml` — ClusterRole pro ArgoCD (kubevirt.io, rhdh.redhat.com, oadp.openshift.io, apps, routes)
- `bootstrap/kustomization.yaml` — resources list

**1c. Operator manifesty**
- `base/operators/rhdh-subscription.yaml` — RHDH Operator (channel: fast-1.10)
- `base/operators/rhdh-operator-namespace.yaml` — Namespace rhdh-operator
- `base/operators/kustomization.yaml`

**1d. Gitea manifesty**
- `base/gitea/deployment.yaml` — gitea/gitea:latest, PVC /data, env pro admin user
- `base/gitea/service.yaml` — ClusterIP port 3000
- `base/gitea/route.yaml` — TLS edge, `__BASE_DOMAIN__` placeholder
- `base/gitea/pvc.yaml` — 10Gi
- `base/gitea/namespace.yaml` + `kustomization.yaml`

**1e. RHDH manifesty**
- `base/rhdh/backstage-cr.yaml` — rhdh.redhat.com/v1alpha5, enableLocalDb: true, route: enabled
- `base/rhdh/app-config-cm.yaml` — auth: development (guest), catalog.locations → Gitea, integrations.github → Gitea API
- `base/rhdh/dynamic-plugins-cm.yaml` — catalog-backend-module-github enabled
- `base/rhdh/namespace.yaml` + `kustomization.yaml`

**1f. Demo environment manifesty**
- `base/demo-env/namespaces.yaml` — vm-dev, vm-staging, vm-prod
- `base/demo-env/quotas.yaml` — ResourceQuota per namespace (vCPU, RAM, storage, VM count)
- `base/demo-env/network-policies.yaml` — izolace mezi namespaces
- `base/demo-env/kustomization.yaml`

**1g. ArgoCD Application manifesty**
- `argocd-apps/phase1-operators.yaml` — Application → base/operators/ (GitHub repo)
- `argocd-apps/phase2-instances.yaml` — Application → base/gitea/ + base/rhdh/ (GitHub repo)
- `argocd-apps/phase3-demo-env.yaml` — Application → base/demo-env/ (GitHub repo)
- Placeholder: `__GITHUB_REPO__`, `__GIT_REVISION__`

**1h. Software Template (Create VM)**
- `templates/catalog-info.yaml` — Backstage Location pointing to create-vm/template.yaml
- `templates/create-vm/template.yaml` — scaffolder v1beta3, JSON Schema (vmName, cpuCores, memoryGi, osImage, environment), publish:github → Gitea, catalog:register
- `templates/create-vm/skeleton/catalog-info.yaml` — Component entity for scaffolded VM
- `templates/create-vm/skeleton/vm-manifests/virtualmachine.yaml` — VirtualMachine CR (pattern from demo-satellite-cloud-native)
- `templates/create-vm/skeleton/vm-manifests/service.yaml`
- `templates/create-vm/skeleton/vm-manifests/cloudinit-secret.yaml`
- `templates/create-vm/skeleton/vm-manifests/kustomization.yaml`

**1i. Scripts**
- `scripts/deploy.sh` — set -euo pipefail, apply_templated(), phased (0-5), oc wait
- `scripts/seed-gitea.sh` — Gitea REST API: create orgs (demo, vm-instances), repos, push templates
- `scripts/create-demo-users.sh` — htpasswd users (admin, developer, approver, viewer)
- `scripts/teardown.sh` — delete ArgoCD apps, namespaces, operator subscriptions

### Krok 2: Validace na clusteru

Jakmile je cluster ready:

```bash
cp .env.sample .env
source .env
./scripts/deploy.sh
```

**Validační checklist:**
- [ ] `oc get applications.argoproj.io -n openshift-gitops` — všechny Synced/Healthy
- [ ] RHDH UI se načte a zobrazí katalog
- [ ] "Create VM" šablona je viditelná v katalogu
- [ ] Vytvořit VM přes šablonu → repo se objeví v Gitea
- [ ] ArgoCD vytvoří Application pro nový repo
- [ ] `oc get vm -n vm-dev` — VM běží

### Krok 3: Orchestration (Phase B)

- Orchestrator plugins v dynamic-plugins.yaml
- SonataFlow workflow s 2-step approval (app owner + security)
- Template triggeruje workflow místo přímého Git publish

### Krok 4: Full Demo (Phase C)

- Resize + Decommission templates
- Netbox + OADP
- Policy enforcement (Scénář B)
- Exception workflow
- Demo scenarios script

## Klíčové soubory — reference z existujícího repo

| Potřebuji | Vzor z repo |
|-----------|-------------|
| ArgoCD Subscription | `demo-acm-gitops/bootstrap/01-gitops-operator.yaml` |
| ArgoCD RBAC | `demo-acm-gitops/bootstrap/02-argocd-rbac.yaml` |
| ApplicationSet | `demo-acm-gitops/bootstrap/03-root-applicationset.yaml` |
| deploy.sh pattern | `demo-satellite-cloud-native/scripts/deploy.sh` |
| apply_templated() | `demo-satellite-cloud-native/scripts/deploy.sh` |
| VirtualMachine CR | `demo-satellite-cloud-native/k8s/base/client-vm.yaml` |
| .env.sample | `demo-satellite-cloud-native/.env.sample` |
| Kustomization labels | `demo-satellite-cloud-native/k8s/base/kustomization.yaml` |

## Rizika

| Risk | Mitigation |
|------|-----------|
| Gitea `publish:github` kompatibilita | Testovat v Phase A. Fallback: `http:backstage:request` |
| ArgoCD SCM Gitea generator | Fallback: monorepo + `git` generator s `directories` |
| RHDH CRD timing | deploy.sh čeká na CSV Succeeded |
| Netbox složitost | Phase C only |
