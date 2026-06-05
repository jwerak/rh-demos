# ACM Operator Lifecycle Management Demo

> **[Česká verze / Czech version](README-cs.md)**

Manage operator installation and upgrades across OpenShift clusters using Red Hat Advanced Cluster Management (ACM) policies. This demo uses the Web Terminal operator as an example to demonstrate version pinning, controlled upgrades, and fleet-wide rollout management via OperatorPolicy.

- [ACM Operator Lifecycle Management Demo](#acm-operator-lifecycle-management-demo)
  - [Overview](#overview)
  - [Prerequisites](#prerequisites)
    - [Deploy a Hosted Cluster](#deploy-a-hosted-cluster)
      - [Option A: GUI (ACM Console)](#option-a-gui-acm-console)
      - [Option B: CLI (hcp)](#option-b-cli-hcp)
    - [Verify the Hosted Cluster](#verify-the-hosted-cluster)
  - [Setup: ClusterSet and Policy Namespace](#setup-clusterset-and-policy-namespace)
  - [Demo Walkthrough](#demo-walkthrough)
    - [1. Discover Available Operator Versions](#1-discover-available-operator-versions)
    - [2. Install Operator at Pinned Version](#2-install-operator-at-pinned-version)
    - [3. Verify Installation at v1.9.0](#3-verify-installation-at-v190)
    - [4. Trigger Controlled Upgrade](#4-trigger-controlled-upgrade)
    - [5. Monitor Upgrade and Verify Compliance](#5-monitor-upgrade-and-verify-compliance)
    - [6. Remove Operator via Policy](#6-remove-operator-via-policy)
  - [Cleanup](#cleanup)
  - [Kustomize Structure](#kustomize-structure)
  - [Policy Generator](#policy-generator)
  - [Additional Resources](#additional-resources)

## Overview

This demo covers three key capabilities:

- **Version Management**: Pin operators to specific versions using OperatorPolicy with `versions` array and `startingCSV`
- **Controlled Upgrades**: Expand the allowed versions list and switch from `inform` (audit) to `enforce` (active remediation) to trigger upgrades
- **Fleet Rollout**: Target specific cluster sets with Placement rules to control which clusters receive the operator

## Prerequisites

- **OpenShift Container Platform 4.14+** with ACM installed
- **OpenShift Virtualization** and **MetalLB** operators installed (for hosted cluster deployment)
- **CLI tools**: `oc`, `hcp`, `kustomize`
- A managed cluster joined to ACM (this demo uses a hosted cluster deployed via HyperShift)

### Deploy a Hosted Cluster

The demo targets a managed cluster. If you don't have one already, deploy a hosted cluster using one of the approaches below.

Reference lab environment: [Using Hosted Control Planes for OpenShift on OpenShift](https://catalog.demo.redhat.com/catalog?search=hcp&item=babylon-catalog-prod%2Fopenshift-cnv.hcp-ocp-virt-cnv.prod) from the Red Hat Demo Platform.

#### Option A: GUI (ACM Console)

1. Log into the OpenShift Console and navigate to **Infrastructure -> Clusters**
2. Verify `local-cluster` is managed and **hypershift-addon** is present under Add-ons
3. Verify credentials: navigate to **Credentials** and confirm `kubevirt-secret` exists (containing a pull-secret and SSH public key). Create it if missing.
4. Go to `local-cluster` and create a project named `clusters` (**Home -> Projects -> Create Project**)
5. Switch back to **All Clusters** view, click **Create cluster**
6. Select **Red Hat OpenShift Virtualization** -> **Hosted** control plane type
7. Configure cluster details:
   - Credential: `kubevirt-secret`
   - Cluster name: `my-hosted-cluster`
   - Cluster set: `default`
   - Release image: OpenShift 4.17.x
   - Etcd storage class: `ocs-external-storagecluster-ceph-rbd`
8. **Toggle YAML On** and change the networking section to avoid CIDR conflicts with the hub:
   ```yaml
   networking:
     clusterNetwork:
       - cidr: 10.136.0.0/14
     serviceNetwork:
       - cidr: 172.32.0.0/16
   ```
9. Click Next and configure node pool: name: my-node-pool, 2 replicas, 2 cores, 8 GiB memory, auto-repair enabled
10. Click **Create** and wait ~15-20 minutes for deployment

#### Option B: CLI (hcp)

```bash
# Extract pull secret from the hub cluster
oc get secret -n openshift-config pull-secret \
  -o template='{{index .data ".dockerconfigjson"}}' | base64 --decode > /tmp/pull-secret.json

# Create the clusters namespace
oc create namespace clusters

# Deploy the hosted cluster
hcp create cluster kubevirt \
  --name my-hosted-cluster \
  --release-image quay.io/openshift-release-dev/ocp-release:4.17.14-x86_64 \
  --node-pool-replicas 2 \
  --pull-secret /tmp/pull-secret.json \
  --memory 8Gi \
  --cores 2 \
  --etcd-storage-class ocs-external-storagecluster-ceph-rbd \
  --namespace clusters \
  --cluster-cidr 10.136.0.0/14 \
  --service-cidr 172.32.0.0/16
```

### Verify the Hosted Cluster

Wait for the cluster to become available (~15-20 minutes):

```bash
watch oc get hostedclusters -n clusters
# Wait for PROGRESS=Completed and AVAILABLE=True

# Verify the cluster is registered as a managed cluster
oc get managedclusters
# Should show my-hosted-cluster with AVAILABLE=True
```

## Setup: ClusterSet and Policy Namespace

Before running the demo, create the namespace, ClusterSet, and bindings:

```bash
# Create the policy namespace
oc create namespace development-policies

# Create the development ClusterSet
cat <<'EOF' | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: development
spec:
  clusterSelector:
    selectorType: ExclusiveClusterSetLabel
EOF

# Add the hosted cluster to the ClusterSet
oc label managedcluster my-hosted-cluster \
  cluster.open-cluster-management.io/clusterset=development --overwrite

# Bind the ClusterSet to the policy namespace
cat <<'EOF' | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: development
  namespace: development-policies
spec:
  clusterSet: development
EOF

# Verify
oc get managedclusterset development
# Should show "1 ManagedClusters selected"
```

## Demo Walkthrough

### 1. Discover Available Operator Versions

List all Web Terminal versions in the `fast` channel:

```bash
oc get packagemanifests.packages.operators.coreos.com \
  -n openshift-marketplace web-terminal \
  -o jsonpath='{range .status.channels[?(@.name=="fast")].entries[*]}- {.name}{"\n"}{end}' \
  | sort -V
```

### 2. Install Operator at Pinned Version

The initial overlay deploys the Web Terminal operator pinned to **v1.9.0** using `enforce` mode. The `versions` array contains only `[web-terminal.v1.9.0]`, which prevents any automatic upgrades.

```bash
kustomize build operators/web-terminal/overlays/initial/ | oc apply -f -
```

### 3. Verify Installation at v1.9.0

Wait ~60-90 seconds for the operator to install:

```bash
oc get policy -n development-policies
# COMPLIANCE STATE should show Compliant — the operator is installed
# and pinned at v1.9.0.

# View detailed compliance message to confirm v1.9.0 is installed
oc get policy development-policies.web-terminal -n my-hosted-cluster \
  -o jsonpath='{.status.details[0].history[0].message}'
# Should report: "Compliant; ... ClusterServiceVersion (web-terminal.v1.9.0) -
#   install strategy completed with no errors"
```

The policy uses `complianceConfig.upgradesAvailable: Compliant`, so it reports Compliant as long as the operator is at a version listed in the `versions` array — even when newer versions exist in the catalog. Upgrades outside the allowed list are held (their InstallPlans remain unapproved) but do not trigger a violation.

### 4. Trigger Controlled Upgrade

The updated overlay expands the `versions` array to include all versions from v1.9.0 through v1.12.1. Since `enforce` mode is active, this triggers the actual upgrade through the version chain.

```bash
kustomize build operators/web-terminal/overlays/updated/ | oc apply -f -
```

### 5. Monitor Upgrade and Verify Compliance

Watch the operator upgrade through versions in real-time:

```bash
# Watch policy compliance
watch oc get policy -n development-policies

# View detailed progress messages (run repeatedly to see upgrade chain)
oc get policy development-policies.web-terminal -n my-hosted-cluster \
  -o jsonpath='{.status.details[0].history[0].message}'
```

The operator automatically upgrades through the version chain: **v1.9.0 -> v1.10.x -> v1.11.x -> v1.12.1**. The full upgrade takes approximately 3-5 minutes.

> **Note:** The policy may briefly show **NonCompliant** during the upgrade while OLM processes InstallPlans and resolves the upgrade path. This is expected during active upgrades.

When complete, the policy will show **Compliant** with message: `ClusterServiceVersion (web-terminal.v1.12.1-...) - install strategy completed with no errors`.

### 6. Remove Operator via Policy

The removed overlay changes `complianceType` from `musthave` to `mustnothave`, which instructs the policy to delete the operator from managed clusters. The `removalBehavior` controls what gets cleaned up: Subscription and CSV are deleted, CRDs are kept, and the OperatorGroup is deleted only if no other operator uses it.

```bash
kustomize build operators/web-terminal/overlays/removed/ | oc apply -f -
```

Wait ~30-60 seconds for the operator to be removed:

```bash
oc get policy -n development-policies
# COMPLIANCE STATE should show Compliant — the operator has been removed.

# Confirm the operator is gone on the managed cluster
oc get policy development-policies.web-terminal -n my-hosted-cluster \
  -o jsonpath='{.status.details[0].history[0].message}'
# Should report: "Compliant; the policy spec is valid, the Subscription was deleted, ..."
```

## Cleanup

```bash
# Remove the policy, placement, and binding
kustomize build operators/web-terminal/overlays/removed/ | oc delete -f -

# Optionally, remove the ClusterSet setup
oc delete managedclustersetbinding development -n development-policies
oc delete managedclusterset development
oc delete namespace development-policies

# Optionally, destroy the hosted cluster
hcp destroy cluster kubevirt --name my-hosted-cluster --namespace clusters
```

## Kustomize Structure

The recommended approach uses a base/overlay pattern in `operators/web-terminal/`:

```
operators/
└── web-terminal/
    ├── base/                          # Common policy components
    │   ├── policy.yaml               # OperatorPolicy (v1.9.0, inform)
    │   ├── placement.yaml            # Targets development ClusterSet
    │   ├── placementbinding.yaml     # Binds policy to placement
    │   └── kustomization.yaml
    └── overlays/
        ├── initial/                   # Enforce mode, single version
        │   └── kustomization.yaml
        ├── updated/                   # Enforce mode, upgrade path to v1.12.1
        │   └── kustomization.yaml    # JSON 6902 patches
        └── removed/                   # Enforce mode, operator removal
            └── kustomization.yaml    # JSON 6902 patches
```

Overlays use JSON 6902 patches to change only what differs from the base:
- **updated**: expands `versions` from `[v1.9.0]` to the full upgrade path
- **removed**: changes `complianceType` to `mustnothave` and adds `removalBehavior` to delete the operator

See [operators/README.md](operators/README.md) for details on adding new operators.

## Policy Generator

ACM includes a PolicyGenerator kustomize plugin for generating policies from templates:

```bash
# Install the plugin: https://github.com/open-cluster-management-io/policy-generator-plugin
kustomize build --enable-alpha-plugins ./policy-generator/configmap/
```

Template-based policies with ConfigMap lookups:

```bash
oc apply -f ./policy-generator/configmap-template/policies.yaml
```

## Additional Resources

- [Getting Started with OperatorPolicy](https://developers.redhat.com/articles/2024/08/08/getting-started-operatorpolicy#)
- [ACM OperatorPolicy Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.11/html/governance/governance#operator-policy)
- [Using Hosted Control Planes for OpenShift on OpenShift](https://catalog.demo.redhat.com/catalog?search=hcp&item=babylon-catalog-prod%2Fopenshift-cnv.hcp-ocp-virt-cnv.prod)
- [Kustomize Documentation](https://kubectl.docs.kubernetes.io/references/kustomize/)
- [OpenShift Operator Lifecycle Manager](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/operators/understanding-operators#operator-lifecycle-manager-olm)
