# Hybrid Cloud Application Demo

This demonstration showcases a hybrid cloud architecture on OpenShift, combining:
- **KubeVirt VirtualMachine** running a legacy PostgreSQL database
- **Containerized applications** (Frontend, Backend API, Redis cache)
- **Topology visualization** in OpenShift Developer Console
- **Kustomize overlays** for multi-environment deployment (Development, Production)

## Architecture Overview

```
┌─────────────────┐
│   Frontend      │ (Container - Nginx)
│   Web UI        │
└────────┬────────┘
         │ HTTP
         ▼
┌─────────────────┐        ┌─────────────────┐
│   Backend       │───────>│     Redis       │ (Container)
│   API Server    │  TCP   │     Cache       │
└────────┬────────┘        └─────────────────┘
         │ SQL
         ▼
┌─────────────────┐
│  PostgreSQL     │ (KubeVirt VM - Legacy System)
│  Database       │
└─────────────────┘
```

### Components

1. **Frontend (Nginx Container)**
   - Static HTML/CSS/JavaScript web interface
   - Proxies API requests to backend
   - Displays system architecture and data
   - Auto-refreshing health checks

2. **Backend (Python/FastAPI Container)**
   - REST API with endpoints for data retrieval
   - Connects to PostgreSQL VM for data storage
   - Uses Redis for caching (5-minute TTL)
   - Health check endpoints for all services

3. **Redis (Container)**
   - Caching layer for database queries
   - Reduces load on PostgreSQL VM
   - Demonstrates hybrid architecture benefits

4. **PostgreSQL VM (KubeVirt VirtualMachine)**
   - Fedora-based VM running PostgreSQL
   - Represents legacy database system
   - Initialized via cloud-init with sample data
   - Demonstrates VM-to-container integration

## Prerequisites

- **OpenShift Container Platform 4.12+** with KubeVirt operator installed
- **oc** CLI tool configured for your cluster
- **kustomize** (optional, for building manifests)
- **podman** (for building custom images)
- Sufficient cluster resources:
  - Development: ~2 vCPU, ~3Gi RAM
  - Production: ~5 vCPU, ~7Gi RAM

### Installing KubeVirt Operator

If KubeVirt is not already installed:

```bash
# Via OpenShift Console
OperatorHub → Search "OpenShift Virtualization" → Install

# Or via CLI
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  channel: stable
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

## Quick Start

### Option 1: Deploy Development Environment

```bash
# Apply development configuration
kustomize build k8s/overlays/development | oc apply -f -

# Or using oc with kustomize built-in
oc apply -k k8s/overlays/development/

# Wait for VM to boot and initialize (3-5 minutes)
oc get vmi -n hybrid-app-dev -w

# Get frontend URL
oc get route -n hybrid-app-dev frontend-dev -o jsonpath='{.spec.host}'
```

### Option 2: Deploy Production Environment

```bash
# Apply production configuration
kustomize build k8s/overlays/production | oc apply -f -

# Or using oc with kustomize built-in
oc apply -k k8s/overlays/production/

# Monitor deployment
oc get pods -n hybrid-app-prod -w

# Get frontend URL
oc get route -n hybrid-app-prod frontend-prod -o jsonpath='{.spec.host}'
```

### Option 3: Deploy Base Configuration

```bash
# Deploy to default namespace (hybrid-app-demo)
kustomize build k8s/base | oc apply -f -

# Or using oc
oc apply -k k8s/base/
```

## Building Custom Images

If you want to build and push your own container images:

```bash
# Set your registry (default: quay.io/jwerak)
export REGISTRY=quay.io/your-username

# Build images
./scripts/build-images.sh

# The script will prompt to push images to the registry
# If you push to a different registry, update the image references in:
# - k8s/base/backend-deployment.yaml
# - k8s/base/frontend-deployment.yaml
```

## Rolling Out Deployments

After making code changes and building new container images, you need to rollout the updated deployments. This section covers different rollout strategies.

### Building and Tagging Images

For production rollouts, use version tags instead of `latest`:

```bash
# Set version tag (e.g., git commit hash or semantic version)
export TAG=v1.2.3
export REGISTRY=quay.io/your-username

# Build and push with version tag
TAG=${TAG} ./scripts/build-images.sh
```

### Rolling Restart (Force Pull Latest)

If using `latest` tag and need to force pull updated image:

```bash
NAMESPACE=hybrid-app-dev

# Rolling restart triggers new pod creation with latest image
oc rollout restart deployment/backend-dev -n ${NAMESPACE}
oc rollout restart deployment/frontend-dev -n ${NAMESPACE}

# Monitor rollout
oc rollout status deployment/backend-dev -n ${NAMESPACE} --timeout=5m
oc rollout status deployment/frontend-dev -n ${NAMESPACE} --timeout=5m
```

### Rollback Procedures

If a rollout causes issues, rollback to the previous revision:

```bash
NAMESPACE=hybrid-app-dev

# View rollout history
oc rollout history deployment/backend-dev -n ${NAMESPACE}
oc rollout history deployment/frontend-dev -n ${NAMESPACE}

# Rollback to previous revision
oc rollout undo deployment/backend-dev -n ${NAMESPACE}
oc rollout undo deployment/frontend-dev -n ${NAMESPACE}

# Rollback to specific revision
oc rollout undo deployment/backend-dev -n ${NAMESPACE} --to-revision=2

# Monitor rollback
oc rollout status deployment/backend-dev -n ${NAMESPACE}
```

### Troubleshooting Failed Rollouts

If a rollout fails or pods are stuck:

```bash
NAMESPACE=hybrid-app-dev

# Check pod events
oc get events -n ${NAMESPACE} --sort-by='.lastTimestamp' | tail -20

# Check pod status
oc get pods -n ${NAMESPACE}

# Describe failing pod
oc describe pod <pod-name> -n ${NAMESPACE}

# Check logs
oc logs <pod-name> -n ${NAMESPACE} --previous  # Previous container if restarted

# Check image pull issues
oc describe pod <pod-name> -n ${NAMESPACE} | grep -A 5 "Events"

# Pause rollout to investigate
oc rollout pause deployment/backend-dev -n ${NAMESPACE}

# Resume after fixing issues
oc rollout resume deployment/backend-dev -n ${NAMESPACE}
```

## Deployment Details

### Development Overlay

- **Namespace**: `hybrid-app-dev`
- **Resources**: Minimal (suitable for resource-constrained environments)
  - Backend: 1 replica, 128Mi RAM, DEBUG logging
  - Frontend: 1 replica, 32Mi RAM
  - PostgreSQL VM: 1 vCPU, 1Gi RAM
  - Redis: 1 replica, 128Mi RAM

### Production Overlay

- **Namespace**: `hybrid-app-prod`
- **Resources**: Production-ready with high availability
  - Backend: 3 replicas, 512Mi RAM, INFO logging
  - Frontend: 2 replicas, 128Mi RAM
  - PostgreSQL VM: 2 vCPUs, 4Gi RAM
  - Redis: 1 replica, 256Mi RAM

### Kustomize Structure

```
k8s/
├── base/                           # Base manifests
│   ├── kustomization.yaml         # Includes all resources + secret generation
│   ├── namespace.yaml
│   ├── postgresql-vm.yaml         # KubeVirt VirtualMachine
│   ├── postgresql-vm-service.yaml
│   ├── redis-deployment.yaml
│   ├── redis-service.yaml
│   ├── backend-deployment.yaml
│   ├── backend-service.yaml
│   ├── frontend-deployment.yaml
│   ├── frontend-service.yaml
│   └── frontend-route.yaml
└── overlays/
    ├── development/               # Dev environment patches
    │   ├── kustomization.yaml
    │   ├── backend-patch.yaml
    │   ├── frontend-patch.yaml
    │   └── postgresql-vm-patch.yaml
    └── production/                # Prod environment patches
        ├── kustomization.yaml
        ├── backend-patch.yaml
        ├── frontend-patch.yaml
        └── postgresql-vm-patch.yaml
```

## Topology Visualization

This demo uses OpenShift's topology view labels and annotations to visualize component connections:

### Labels for Grouping
```yaml
app.kubernetes.io/part-of: hybrid-app     # Groups all components
app.kubernetes.io/name: <component-name>  # Component identifier
app.openshift.io/runtime: <runtime-icon>  # Icon in topology view
```

### Annotations for Connections
```yaml
app.openshift.io/connects-to: '[{"apiVersion":"v1","kind":"Service","name":"<target>"}]'
```

**To view the topology:**
1. Open OpenShift Console
2. Switch to **Developer** perspective
3. Select your namespace (`hybrid-app-dev` or `hybrid-app-prod`)
4. Click **Topology**
5. You should see:
   - Frontend → Backend connection
   - Backend → PostgreSQL VM connection
   - Backend → Redis connection

## Testing and Verification

### 1. Check VM Status

```bash
# Check VirtualMachine and VirtualMachineInstance
oc get vm,vmi -n hybrid-app-dev

# View VM console (optional)
virtctl console postgresql-vm -n hybrid-app-dev
```

### 2. Verify All Pods are Running

```bash
oc get pods -n hybrid-app-dev

# Expected output:
# NAME                        READY   STATUS    RESTARTS   AGE
# backend-dev-xxx             1/1     Running   0          5m
# frontend-dev-xxx            1/1     Running   0          5m
# redis-dev-xxx               1/1     Running   0          5m
# virt-launcher-postgresql-vm 1/1     Running   0          5m
```

### 3. Test Database Connectivity

```bash
# Check if backend can query PostgreSQL
oc logs -n hybrid-app-dev deployment/backend --tail=50

# You should see successful PostgreSQL connections in logs
```

### 4. Access the Web UI

```bash
# Get frontend URL
echo "https://$(oc get route -n hybrid-app-dev frontend-dev -o jsonpath='{.spec.host}')"

# Open in browser and verify:
# - All health checks are "healthy"
# - Data can be loaded from PostgreSQL
# - Cache statistics are displayed
# - Topology diagram is visible
```

## API Endpoints

The backend exposes the following REST API endpoints:

| Endpoint           | Method | Description                       |
| ------------------ | ------ | --------------------------------- |
| `/`                | GET    | API information                   |
| `/health`          | GET    | Health check for all services     |
| `/api/data`        | GET    | Retrieve data (cached or from DB) |
| `/api/cache-stats` | GET    | Redis cache statistics            |
| `/api/cache`       | DELETE | Clear all cached data             |

## Troubleshooting

### VM Not Starting

```bash
# Check VM events
oc describe vm postgresql-vm -n hybrid-app-dev

# Check if KubeVirt is installed
oc get kubevirt -A

# Verify DataVolume provisioning
oc get dv -n hybrid-app-dev
```

### Backend Cannot Connect to PostgreSQL

```bash
# Check if VM is running
oc get vmi -n hybrid-app-dev

# Check PostgreSQL service
oc get svc postgresql-vm -n hybrid-app-dev

# Test connection from backend pod
oc exec -n hybrid-app-dev deployment/backend -- \
  nc -zv postgresql-vm 5432
```

### Cache Not Working

```bash
# Check Redis pod
oc get pods -n hybrid-app-dev -l app=redis

# Check Redis logs
oc logs -n hybrid-app-dev deployment/redis

# Test Redis connection
oc exec -n hybrid-app-dev deployment/backend -- \
  nc -zv redis 6379
```

### View Backend Logs

```bash
# Real-time logs
oc logs -n hybrid-app-dev deployment/backend -f

# Logs with DEBUG level (development only)
oc logs -n hybrid-app-dev deployment/backend --tail=100 | grep DEBUG
```

## Clean Up

### Remove Development Environment

```bash
oc delete -k k8s/overlays/development/

# Or manually
oc delete namespace hybrid-app-dev
```

### Remove Production Environment

```bash
oc delete -k k8s/overlays/production/

# Or manually
oc delete namespace hybrid-app-prod
```

### Remove Base Installation

```bash
oc delete -k k8s/base/

# Or manually
oc delete namespace hybrid-app-demo
```

## Use Cases Demonstrated

1. **Hybrid Cloud Integration**
   - Legacy VM-based databases integrated with cloud-native containers
   - Demonstrates migration path for traditional workloads

2. **Multi-tier Architecture**
   - Separation of concerns (presentation, business logic, data, cache)
   - Service mesh connectivity patterns

3. **Multi-environment Management**
   - Kustomize overlays for environment-specific configurations
   - Resource optimization per environment

4. **Topology Visualization**
   - Clear visualization of component relationships
   - Runtime dependency mapping

5. **Cloud-native Patterns**
   - Health checks and readiness probes
   - Horizontal pod autoscaling ready
   - Secrets management

## Future Enhancements

Potential additions to this demo:
- VM migration demonstration (live migration)
- Horizontal Pod Autoscaler (HPA) configuration
- Monitoring with Prometheus/Grafana
- Message queue integration (RabbitMQ/Kafka)
- CI/CD pipeline with Tekton
- Service mesh (Istio) integration
- Backup and disaster recovery procedures

## References

- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about-virt.html)
- [KubeVirt Project](https://kubevirt.io/)
- [Kustomize Documentation](https://kustomize.io/)
- [OpenShift Topology View](https://docs.openshift.com/container-platform/latest/applications/odc-viewing-application-composition-using-topology-view.html)

## Contributing

To contribute improvements to this demo:
1. Build and test your changes locally
2. Ensure all components deploy successfully
3. Update documentation as needed
4. Submit changes following repository guidelines
