# demo-foreman-PF6

Foreman (PatternFly 6) lifecycle management demo on OpenShift Virtualization.

## Architecture

Single RHEL 9 VM running Foreman via podman-compose (6 containers: app, db, orchestrator, worker, redis-cache, redis-tasks). Client VMs register to Foreman via the Global Registration endpoint. All VMs use masquerade networking on the default pod network.

```
Route (edge TLS) → Service :3000 → Foreman VM (podman-compose)
                                         ↑
                                    Client VMs register via curl
```

## Components

| Component | Description |
|---|---|
| Foreman VM | 4 vCPU, 8Gi RAM, 50Gi — runs all Foreman services via podman-compose |
| Client VM | 1 vCPU, 2Gi RAM, 30Gi — auto-registers to Foreman |
| Client Pool | VirtualMachinePool, starts at 0 replicas |

## Important

- DNS CNAME required: `FOREMAN_FQDN` must point to the OpenShift router wildcard
- `rhsm-credentials` secret must exist before deployment (run `scripts/create-rhsm-secret.sh`)
- Foreman container image must be pre-built and pushed to registry (run `scripts/build-push-image.sh`)
- Manifests use placeholders (`__FOREMAN_FQDN__`, `__DEMO_PASSWORD__`, `__FOREMAN_IMAGE__`, `__FOREMAN_DOMAIN__`) — always deploy via `scripts/deploy.sh`

## Directory Structure

```
k8s/base/           Kubernetes manifests (VM, cloud-init, service, route)
k8s/overlays/demo/  Demo overlay (adds environment: demo label)
scripts/            Deployment, verification, and demo scripts
```

## Key Commands

```bash
# Build and push Foreman image
./scripts/build-push-image.sh --push

# Deploy
source .env
./scripts/create-rhsm-secret.sh
./scripts/deploy.sh

# Verify
./scripts/verify.sh

# Run demos
./scripts/demo-scenarios.sh 1   # Zero-touch provisioning
./scripts/demo-scenarios.sh 2   # Elastic scaling
```

## Credentials

| Service | User | Password |
|---|---|---|
| Foreman Web UI | admin | `$DEMO_PASSWORD` (saved to .env) |
| VM SSH | cloud-user | `$DEMO_PASSWORD` |

## Tools Required

`oc`, `podman`, `virtctl`, `sshpass`, `curl`

## Namespace

`foreman-demo`
