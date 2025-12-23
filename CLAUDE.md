# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a collection of Red Hat technology demonstrations, primarily focused on Ansible automation, OpenShift/ACM management, and AIOps implementations. The repository is structured as a multi-demo collection, each in its own directory with specific focus areas.

## Architecture

### Unified Demo Deployment System

The repository uses a centralized Ansible-based deployment system located in `ansible-controller/`:

- **Main playbook**: `ansible-controller/main.yml` - Orchestrates all demo deployments
- **Execution tool**: `ansible-navigator` with containerized execution environments
- **Role-based deployment**: Each demo has a corresponding role in `ansible-controller/roles/`
- **Inventory system**: Demo-specific inventories in `ansible-controller/inventory/`

**Two deployment patterns**:
1. **VM-based demos** (e.g., `demo-network-manager`): Provisions VMs via libvirt, then configures them
2. **Container-based demos** (e.g., `demo-containerfile`): Runs directly on localhost without VM provisioning

### Demo Categories

**AIOps Demonstrations** (`demo-aiops/`):
- `aiops-aap/`: AAP-based AIOps demo setup with workflow automation
- `aiops-agent/`: Agent-based AIOps using Python, deployed to OpenShift
  - `ops-assistant/`: Python-based ops incident assistant (uses Kustomize overlays from upstream GitHub repo)
  - `mcp-server-aap/`: MCP server for AAP integration (uses Kustomize overlays from upstream GitHub repo)

**Infrastructure Management**:
- `demo-acm-policies/`: ACM policy-based operator lifecycle management (version pinning, controlled upgrades)
- `demo-system-roles/`: RHEL System Roles for host registration, Cockpit, monitoring
- `demo-network-manager/`: RHEL 10 NetworkManager IP alias management

**Container Development**:
- `demo-containerfile/`: Demonstrates manifest-driven tar archive approach for copying multiple files into container images
- `demo-podman-build-push-run/`: Basic Podman container workflow

**Hybrid Cloud / Virtualization**:
- `demo-hybrid-app/`: Hybrid cloud application demonstrating KubeVirt VM integration with containers
  - KubeVirt VirtualMachine running PostgreSQL (legacy database)
  - Containerized applications (Frontend, Backend API, Redis cache)
  - Topology visualization in OpenShift Developer Console
  - Kustomize overlays for multi-environment deployment (development, production)

## Common Commands

### Running Demos via Unified Controller

**For demos without VM provisioning**:
```bash
cd ansible-controller
ansible-navigator run --extra-vars "demo_name=demo-containerfile"
```

**For demos requiring VM provisioning** (e.g., network-manager):
```bash
cd ansible-controller
ansible-navigator run -i inventory/demo-network-manager.yml --extra-vars "demo_name=demo-network-manager provisioner=libvirt"
```

Available demo names: `aiops`, `demo-acm-policies`, `demo-containerfile`, `demo-hybrid-app`, `demo-network-manager`, `demo-podman-build-push-run`, `demo-satellite`, `demo-system-roles`

### AIOps - AAP Setup

```bash
cd demo-aiops/aiops-aap
source .env  # After copying .env.sample to .env and filling in AAP credentials
ansible-navigator run playbooks/aiops-workflows.yml --penv CONTROLLER_USERNAME --penv CONTROLLER_PASSWORD --penv CONTROLLER_HOST
```

### AIOps - Agent Deployment (OpenShift)

**Deploy MCP Server for AAP**:
```bash
cd demo-aiops/aiops-agent
# Update patches: ocp/mcp-server-aap/patch-configmap.yaml and secret.yaml
oc apply -k ocp/mcp-server-aap
oc get route mcp-server-aap -n mcp-server-aap -o jsonpath='{.spec.host}'
```

**Deploy Ops Assistant Agent**:
```bash
cd demo-aiops/aiops-agent
# Update patches: ocp/ops-assistant/patch-configmap.yaml and patch-secret.yaml
oc new-project aiops
oc apply -k ocp/ops-assistant/
oc get route -n aiops ops-incident-assistant
```

**Test the agent**:
```bash
ROUTE_OPS_ASSISTANT=$(oc get route -n aiops ops-incident-assistant -o jsonpath='{.spec.host}')
curl -X POST https://${ROUTE_OPS_ASSISTANT}/webhook/7d1a79c6-2189-47d5-92c6-dfbac5b1fa59 \
  -H "Content-Type: application/json" \
  -d '{"question": "What job templates are available?"}'
```

**View logs**:
```bash
oc logs -l app=ops-incident-assistant -n aiops --tail=100 -f
```

### RHEL System Roles Demo

```bash
cd demo-system-roles
ansible-navigator run jwerak.cloud.libvirt_vm_setup -e target=lab_hosts  # Create VMs
ansible-navigator inventory  # View inventory
ansible-navigator run playbooks/rhc.yml -e @./vault.yml  # Register hosts
ansible-navigator run playbooks/cockpit.yml  # Install Cockpit
ansible-navigator run playbooks/monitoring.yml  # Enable monitoring
```

### ACM Policies Demo

**Query available operator versions**:
```bash
cd demo-acm-policies
oc get packagemanifests.packages.operators.coreos.com -n openshift-marketplace web-terminal -o yaml
oc get packagemanifests.packages.operators.coreos.com -n openshift-marketplace web-terminal -o jsonpath='{range .status.channels[?(@.name=="fast")].entries[*]}- {.name}{"\n"}{end}' | sort -V
```

**Apply policies using kustomize (recommended)**:
```bash
# Install operator at v1.9.0
kustomize build operators/web-terminal/overlays/initial/ | oc apply -f -

# Upgrade to v1.10.1
kustomize build operators/web-terminal/overlays/updated/ | oc apply -f -

# Monitor upgrade
watch oc get csv -n openshift-operators
```

**Apply policies using legacy files**:
```bash
oc apply -f files/policy-web-terminal-initial.yml  # Install operator at v1.9.0
oc apply -f files/policy-web-terminal-updated.yml  # Upgrade to v1.10.1
```

**Generate policies with kustomize plugin**:
```bash
kustomize build --enable-alpha-plugins ./policy-generator/configmap/
```

### Containerfile Demo

```bash
cd demo-containerfile
./create-archive.sh  # Create main.tar.gz from manifest
./build-and-test.sh  # Build and test the image
podman run --rm -it demo-file-copy:latest /bin/bash  # Interactive exploration
```

### Hybrid Cloud Application Demo

**Prerequisites**: OpenShift cluster with KubeVirt operator installed

**Build container images (optional)**:
```bash
cd demo-hybrid-app
./scripts/build-images.sh
# Follow prompts to build and optionally push images
```

**Deploy to development environment**:
```bash
cd demo-hybrid-app
oc apply -k k8s/overlays/development/
# Or using kustomize directly
kustomize build k8s/overlays/development/ | oc apply -f -
```

**Deploy to production environment**:
```bash
cd demo-hybrid-app
oc apply -k k8s/overlays/production/
```

**Via ansible-controller**:
```bash
cd ansible-controller
# Deploy development environment
ansible-navigator run --extra-vars "demo_name=demo-hybrid-app environment=development"

# Deploy production environment
ansible-navigator run --extra-vars "demo_name=demo-hybrid-app environment=production"

# Build images and deploy
ansible-navigator run --extra-vars "demo_name=demo-hybrid-app environment=development build_images=true"
```

**Verify deployment**:
```bash
# Check all resources
oc get all -n hybrid-app-dev

# Check VirtualMachine status
oc get vm,vmi -n hybrid-app-dev

# Get frontend URL
oc get route -n hybrid-app-dev frontend-dev -o jsonpath='{.spec.host}'

# View topology in OpenShift Console
# Developer perspective → Topology → Select namespace hybrid-app-dev
```

**Monitor PostgreSQL VM initialization** (takes 3-5 minutes):
```bash
oc get vmi -n hybrid-app-dev -w
```

**Cleanup**:
```bash
# Remove development environment
oc delete -k k8s/overlays/development/

# Remove production environment
oc delete -k k8s/overlays/production/
```

## Key Architectural Patterns

### Kustomize Overlays from External Repos

The AIOps agent demos (`ops-assistant/` and `mcp-server-aap/`) use Kustomize overlays that reference upstream GitHub repositories as bases. This keeps local changes minimal and allows upstream updates.

Pattern:
```yaml
resources:
  - https://github.com/jwerak/mcp-server-aap/k8s/base
patches:
  - path: patch-configmap.yaml
  - path: secret.yaml
```

### Manifest-Driven Container File Copying

`demo-containerfile/` demonstrates a pattern for copying multiple files to container images:
1. Define files in `archive-manifest.txt`
2. Create single `main.tar.gz` with `create-archive.sh`
3. Use `ADD` directive in Containerfile to auto-extract and merge with container filesystem

### ACM Policy-Based Operator Management

`demo-acm-policies/` shows how to:
- Pin operators to specific versions using `startingCSV`
- Control upgrades by expanding the `versions` array in OperatorPolicy
- Use kustomize base/overlay pattern for operator policies (`operators/<operator-name>/`)
- Separate initial deployment from upgrade configurations using overlays
- Use PolicyGenerator (kustomize plugin) to generate policies from templates
- Manage rollouts across cluster sets

**Structure Pattern:**
```
operators/<operator-name>/
├── base/          # Common policy, placement, binding
└── overlays/
    ├── initial/   # Fresh deployment (inform mode, single version)
    └── updated/   # Upgrade path (enforce mode, multiple versions)
```

### Hybrid Cloud Architecture with KubeVirt

`demo-hybrid-app/` demonstrates integration of VirtualMachines with containerized applications:
- KubeVirt VirtualMachine for legacy workloads (PostgreSQL database)
- Cloud-init for VM provisioning and configuration
- Service-based connectivity between VMs and containers
- Topology visualization using OpenShift labels and annotations
- Multi-environment deployment with Kustomize overlays

**Key Features:**
- **Topology Visualization**: Uses `app.kubernetes.io/part-of` for grouping and `app.openshift.io/connects-to` for connection arrows
- **Multi-Environment**: Development and Production overlays with different resource allocations
- **Hybrid Integration**: Demonstrates how legacy VM-based services can integrate with cloud-native containers
- **Cloud-Init**: Automated PostgreSQL installation and data initialization in VM

**Topology Labels Pattern:**
```yaml
metadata:
  labels:
    app.kubernetes.io/part-of: hybrid-app           # Groups components
    app.kubernetes.io/name: <component-name>        # Component identifier
    app.openshift.io/runtime: <icon>                # Icon in topology
  annotations:
    app.openshift.io/connects-to: '[{"apiVersion":"v1","kind":"Service","name":"<target>"}]'
```

### Ansible-Navigator Execution Model

All playbooks use `ansible-navigator` with:
- Containerized execution environments
- Inventory management per demo
- Support for both local and remote (libvirt) provisioning
- Environment variable passing with `--penv`

## File Organization

- **Demo directories** (`demo-*/`): Self-contained with own README, playbooks, and resources
- **Ansible Controller** (`ansible-controller/`): Central orchestration with roles and inventories
- **Git repo**: Clean working directory expected; demos are designed to be repeatable
- **Environment files**: Use `.env.sample` as template, copy to `.env` (gitignored) for credentials
