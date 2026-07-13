# CLAUDE.md

Self-service VM portal: RHDH 1.10 + GitLab CE + ArgoCD + OpenShift Virtualization.
Users order VMs through RHDH Software Templates, which publish to GitLab repos discovered by ArgoCD SCM Provider, creating VMs via GitOps.

## Components

- **RHDH 1.10** (Operator) — Developer portal with Software Templates + Orchestrator for VM ordering
- **GitLab CE** (on-cluster) — Git server hosting scaffolded VM repos and template catalog
- **OpenShift GitOps** (ArgoCD) — Watches GitLab groups for new repos, syncs VM manifests
- **OpenShift Virtualization** — Runs VMs created by ArgoCD from Git-managed manifests
- **OpenShift Serverless Logic** (SonataFlow) — Workflow engine for approval-based VM provisioning
- **Keycloak** — OIDC identity provider with role-based groups

## Architecture: Two Git Servers

- **GitHub** (rh-demos repo): ArgoCD reads infrastructure manifests
- **GitLab** (on-cluster): RHDH templates/catalog + scaffolded VM repos

## VM Ordering GitOps Loop

```
User → RHDH Template → publish:gitlab → GitLab repo (vm-instances/<vm-name>)
                                              ↓
ArgoCD SCM Provider (watches vm-instances group) → discovers new repo
                                              ↓
ArgoCD syncs VirtualMachine CR → OCP Virt creates VM
```

## Directory Structure

- `bootstrap/` — GitOps Operator + RBAC (applied by deploy.sh Phase 1)
- `argocd-apps/` — ArgoCD Application manifests (applied by deploy.sh)
- `base/operators/` — RHDH Operator Subscription
- `base/gitlab/` — GitLab CE Deployment, Service, Route, PVCs, SCC
- `base/rhdh/` — Backstage CR, app-config, dynamic-plugins
- `base/demo-env/` — Namespaces, Quotas, NetworkPolicies for vm-dev/staging/prod
- `base/keycloak/` — Keycloak deployment, realm config (users, groups, OIDC)
- `base/serverless/` — Serverless + Serverless Logic Operator Subscriptions
- `base/orchestrator/` — SonataFlowPlatform CR, workflow SonataFlow CRs
- `templates/` — RHDH Software Templates (Create VM, Resize VM, Decommission VM, Policy Test)
- `workflows/` — SonataFlow workflow definitions (request-vm-approval)
- `scripts/` — deploy.sh, seed-gitlab.sh, create-demo-users.sh, teardown.sh

## Key Commands

```bash
# Deploy (single entry point)
cp .env.sample .env    # Edit with your values
source .env
./scripts/deploy.sh                        # Installs GitOps, RHDH, GitLab, seeds templates
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
| `BASE_DOMAIN` | Custom domain for portal routes (e.g. virt-portal.example.com) |
| `GITLAB_ADMIN_PASSWORD` | GitLab root password |
| `GITLAB_TOKEN` | GitLab PAT for RHDH integration (set here, created by seed-gitlab.sh) |
| `BACKEND_SECRET` | RHDH backend auth secret |
| `DEMO_PASSWORD` | Password for htpasswd demo users |
| `GITHUB_REPO` | Git repo URL for ArgoCD (this repo) |
| `GIT_REVISION` | Git branch/revision for ArgoCD |

## Tools Required

- `oc` — OpenShift CLI
- `curl` — for GitLab API (seed-gitlab.sh)
- `htpasswd` — for demo users (create-demo-users.sh)
