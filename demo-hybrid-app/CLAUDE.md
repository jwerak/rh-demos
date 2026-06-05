# CLAUDE.md

Hybrid cloud demo: KubeVirt VM (PostgreSQL) + containerized apps (Frontend, Backend, Redis) on OpenShift.

## Components

- **Frontend** (Nginx container) - static UI, proxies API to backend
- **Backend** (Python/FastAPI container) - REST API, connects to PostgreSQL and Redis
- **Redis** (container) - cache layer with 5-min TTL
- **PostgreSQL VM** (KubeVirt VirtualMachine) - Fedora VM, initialized via cloud-init

## Directory Structure

- `container-images/backend/` - Backend app source + Containerfile
- `container-images/frontend/` - Frontend source + Containerfile + nginx config
- `scripts/build-images.sh` - Build and optionally push images (uses `REGISTRY` and `TAG` env vars)
- `k8s/` - Kubernetes/OpenShift manifests (Kustomize)

## Kustomize Layout

```
k8s/base/          # All resources: namespace, deployments, services, route, VM, DataVolume, cloud-init secret
k8s/overlays/
  development/     # NS: hybrid-app-dev, 1 replica, minimal resources, DEBUG logging
  production/      # NS: hybrid-app-prod, 2-3 replicas, higher resources, INFO logging
```

Overlays patch: backend, frontend, postgresql-vm, frontend-route (name prefix + namespace).

## Key Commands

```bash
# Deploy dev
oc apply -k k8s/overlays/development/

# Deploy prod
oc apply -k k8s/overlays/production/

# Wait for VM boot (3-5 min)
oc get vmi -n hybrid-app-dev -w

# Verify
oc get pods -n hybrid-app-dev
oc get vm,vmi -n hybrid-app-dev
echo "https://$(oc get route -n hybrid-app-dev frontend-dev -o jsonpath='{.spec.host}')"

# Rolling restart after image update
oc rollout restart deployment/backend-dev -n hybrid-app-dev
oc rollout restart deployment/frontend-dev -n hybrid-app-dev

# Build images
REGISTRY=quay.io/your-user TAG=v1.0 ./scripts/build-images.sh

# Cleanup
oc delete -k k8s/overlays/development/
oc delete -k k8s/overlays/production/
```

## Tools Required

- `oc` - OpenShift CLI (cluster must have KubeVirt/OpenShift Virtualization operator)
- `kustomize` - manifest building (or use `oc apply -k`)
- `podman` - container image builds

## API Endpoints (Backend)

`/health`, `/api/data`, `/api/cache-stats`, `DELETE /api/cache`
