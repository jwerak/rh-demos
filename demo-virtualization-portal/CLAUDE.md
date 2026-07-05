# CLAUDE.md

Self-service VM portal: RHDH 1.10 + Gitea + ArgoCD + OpenShift Virtualization.
Users order VMs through RHDH Software Templates, which publish to Gitea repos discovered by ArgoCD SCM Provider, creating VMs via GitOps.

## Components

- **RHDH 1.10** (Operator) — Developer portal with Software Templates for VM ordering
- **Gitea** (on-cluster) — Git server hosting scaffolded VM repos and template catalog
- **OpenShift GitOps** (ArgoCD) — Watches Gitea orgs for new repos, syncs VM manifests
- **OpenShift Virtualization** — Runs VMs created by ArgoCD from Git-managed manifests

## Architecture: Two Git Servers

- **GitHub** (rh-demos repo): ArgoCD reads infrastructure manifests
- **Gitea** (on-cluster): RHDH templates/catalog + scaffolded VM repos

## VM Ordering GitOps Loop

```
User → RHDH Template → publish:github → Gitea repo (vm-instances/<vm-name>)
                                              ↓
ArgoCD SCM Provider (watches vm-instances org) → discovers new repo
                                              ↓
ArgoCD syncs VirtualMachine CR → OCP Virt creates VM
```

## Directory Structure

- `bootstrap/` — GitOps Operator + RBAC (applied by deploy.sh Phase 1)
- `argocd-apps/` — ArgoCD Application manifests (applied by deploy.sh)
- `base/operators/` — RHDH Operator Subscription
- `base/gitea/` — Gitea Deployment, Service, Route, PVC
- `base/rhdh/` — Backstage CR, app-config, dynamic-plugins
- `base/demo-env/` — Namespaces, Quotas, NetworkPolicies for vm-dev/staging/prod
- `templates/` — RHDH Software Templates (Create VM)
- `scripts/` — deploy.sh, seed-gitea.sh, create-demo-users.sh, teardown.sh

## Key Commands

```bash
# Deploy (single entry point)
cp .env.sample .env    # Edit with your values
source .env
./scripts/deploy.sh                        # Installs GitOps, RHDH, Gitea, seeds templates
./scripts/create-demo-users.sh            # Create htpasswd demo users

# Verify
oc get applications.argoproj.io -n openshift-gitops
oc get backstage -n rhdh
oc get vm -n vm-dev

# Teardown
./scripts/teardown.sh
```

## Environment Variables (.env)

| Variable | Description |
|----------|-------------|
| `BASE_DOMAIN` | Cluster apps domain (e.g. apps.cluster.example.com) |
| `GITEA_ADMIN_USER` | Gitea admin username |
| `GITEA_ADMIN_PASSWORD` | Gitea admin password |
| `BACKEND_SECRET` | RHDH backend auth secret |
| `DEMO_PASSWORD` | Password for htpasswd demo users |
| `GITHUB_REPO` | Git repo URL for ArgoCD (this repo) |
| `GIT_REVISION` | Git branch/revision for ArgoCD |

## Tools Required

- `oc` — OpenShift CLI
- `curl` — for Gitea API (seed-gitea.sh)
- `htpasswd` — for demo users (create-demo-users.sh)
