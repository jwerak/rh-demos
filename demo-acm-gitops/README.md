# ACM GitOps: Operator Lifecycle with Dev-to-Prod Promotion

Manage operator installation and upgrades across OpenShift clusters using ArgoCD + ACM OperatorPolicy. This demo provisions HCP clusters, deploys operators (Web Terminal, Quay), and demonstrates git-based promotion from dev to prod.

> For the basic demo without GitOps, see [ACM Operator Lifecycle Management](../demo-acm-policies/README-basic.md).

## Overview

- **GitOps-managed HCP clusters**: ArgoCD provisions dev and prod hosted clusters via HostedCluster CRs
- **ACM OperatorPolicy**: Operators deployed to managed clusters through ACM policy enforcement
- **Dev-to-prod promotion**: Adding an operator to prod = adding a kustomize base reference + git push
- **ApplicationSet auto-discovery**: ArgoCD automatically discovers new environments from the directory structure

## Prerequisites

- **OpenShift Container Platform 4.14+** with ACM/MCE installed
- **OpenShift Virtualization** and **MetalLB** operators installed
- **CLI tools**: `oc`, `kustomize`
- Sufficient cluster resources for 2 HCP clusters (~8 cores + 32GB RAM total)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Git Repository (this repo)                                     │
│                                                                 │
│  environments/dev/clusters/    environments/prod/clusters/       │
│  environments/dev/policies/    environments/prod/policies/       │
└──────────────────────┬──────────────────────────────────────────┘
                       │ ArgoCD ApplicationSet
                       │ (git directory generator)
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│  Hub Cluster (ArgoCD + ACM)                                     │
│                                                                 │
│  ┌──────────────────┐  ┌──────────────────┐                     │
│  │ dev-clusters app  │  │ prod-clusters app │                    │
│  │ (HostedCluster)   │  │ (HostedCluster)   │                   │
│  └────────┬─────────┘  └────────┬──────────┘                    │
│           │                     │                                │
│  ┌────────▼─────────┐  ┌───────▼───────────┐                    │
│  │  dev-cluster HCP  │  │ prod-cluster HCP  │                   │
│  └────────┬─────────┘  └───────┬───────────┘                    │
│           │                     │                                │
│  ┌────────▼─────────┐  ┌───────▼───────────┐                    │
│  │ dev-policies app  │  │ prod-policies app │                    │
│  │ ACM OperatorPolicy│  │ ACM OperatorPolicy│                   │
│  │ • Web Terminal    │  │ • Web Terminal     │                   │
│  │ • Quay            │  │ (Quay after promo) │                   │
│  └──────────────────┘  └───────────────────┘                    │
└─────────────────────────────────────────────────────────────────┘
```

## Demo Walkthrough

### 1. Create Cluster Secrets

Before ArgoCD can provision HCP clusters, create the required secrets:

```bash
oc create namespace clusters  # if it doesn't exist

./bootstrap/create-secrets.sh dev-cluster
./bootstrap/create-secrets.sh prod-cluster
```

### 2. Bootstrap GitOps

Install the OpenShift GitOps operator, configure RBAC, and deploy the root ApplicationSet:

```bash
# Phase 1: Install GitOps operator, namespaces, and RBAC
oc apply -k bootstrap/

# Wait for the GitOps operator to install (~2-3 minutes)
watch oc get csv -n openshift-gitops
# Wait for openshift-gitops-operator to reach Succeeded

# Phase 2: Deploy the root ApplicationSet (requires GitOps CRDs to exist)
oc apply -f bootstrap/03-root-applicationset.yaml
```

### 3. Verify ArgoCD Applications

The ApplicationSet auto-discovers environments and creates four ArgoCD Applications:

```bash
oc get applicationset -n openshift-gitops
# acm-gitops-demo

oc get applications.argoproj.io -n openshift-gitops
# dev-clusters      Synced  Healthy
# dev-policies      Synced  Healthy
# prod-clusters     Synced  Healthy
# prod-policies     Synced  Healthy
```

### 4. Monitor HCP Cluster Provisioning

ArgoCD applies the HostedCluster CRs, triggering cluster provisioning (~15-20 minutes):

```bash
watch oc get hostedclusters -n clusters
# Wait for dev-cluster and prod-cluster to reach PROGRESS=Completed

oc get managedclusters
# dev-cluster    true   https://...   True   True
# prod-cluster   true   https://...   True   True
```

### 5. Label Clusters into ClusterSets

Once clusters are available, add them to their respective ClusterSets:

```bash
oc label managedcluster dev-cluster \
  cluster.open-cluster-management.io/clusterset=dev --overwrite

oc label managedcluster prod-cluster \
  cluster.open-cluster-management.io/clusterset=prod --overwrite
```

### 6. Verify Operator Deployment

ACM policies enforce operator installation on the managed clusters:

```bash
# Dev: both Web Terminal and Quay
oc get policy -n dev-policies
# web-terminal    enforce   Compliant
# quay-operator   enforce   Compliant

# Prod: Web Terminal only (Quay not yet promoted)
oc get policy -n prod-policies
# web-terminal    enforce   Compliant
```

### 7. Promote Quay to Production

To promote Quay from dev to prod, add the Quay base reference to the prod policies overlay:

Edit `environments/prod/policies/kustomization.yaml`:

```yaml
resources:
  - ../../../base/policies/web-terminal
  - ../../../base/policies/quay          # Add this line
```

Commit and push:

```bash
git add environments/prod/policies/kustomization.yaml
git commit -m "Promote Quay operator to production"
git push
```

ArgoCD detects the change and syncs automatically:

```bash
# Watch ArgoCD sync
oc get applications.argoproj.io prod-policies -n openshift-gitops

# Verify Quay policy appears in prod
oc get policy -n prod-policies
# web-terminal    enforce   Compliant
# quay-operator   enforce   Compliant
```

### 8. Upgrade Web Terminal on Dev (v1.9.0 → v1.14.0)

The dev overlay expands the `versions` array in the web-terminal policy to allow upgrades through the full version chain. The base pins to v1.9.0; the dev overlay already includes versions up to v1.14.0.

```bash
# Check current version on dev-cluster
oc get policy dev-policies.web-terminal -n dev-cluster \
  -o jsonpath='{.status.details[0].history[0].message}' | grep -o 'web-terminal\.[^ ]*'

# Watch the upgrade progress (v1.9.0 → v1.10.x → v1.11.x → v1.12.x → v1.13.0 → v1.14.0)
watch oc get policy -n dev-policies
# Policy will briefly show NonCompliant during upgrade, then Compliant at v1.14.0
```

The upgrade takes approximately 3-5 minutes as OLM processes the version chain.

### 9. Promote Upgrade to Production

Once dev is validated at v1.14.0, add the same versions patch to `environments/prod/policies/kustomization.yaml`:

```yaml
patches:
  - target:
      kind: Policy
      name: web-terminal
    patch: |-
      - op: replace
        path: /metadata/namespace
        value: prod-policies
      - op: replace
        path: /spec/policy-templates/0/objectDefinition/spec/versions
        value:
          - web-terminal.v1.14.0
          - web-terminal.v1.13.0
          - web-terminal.v1.12.1
          - web-terminal.v1.11.1
          - web-terminal.v1.11.0
          - web-terminal.v1.10.1
          - web-terminal.v1.10.0
          - web-terminal.v1.9.0
```

Commit and push:

```bash
git add environments/prod/policies/kustomization.yaml
git commit -m "Promote web-terminal v1.14.0 upgrade to production"
git push
```

## Reset to Starting Point

To undo all demo changes and return to the initial state (v1.9.0, no Quay in prod):

```bash
# Revert to the initial commit of the demo (before any promotion/upgrade changes)
git checkout origin/master -- demo-acm-gitops/environments/
git commit -m "Reset environments to initial state"
git push

# ArgoCD auto-syncs: versions revert to v1.9.0, Quay removed from prod
# Note: OLM does not downgrade operators — the operator stays at the upgraded
# version but the policy will show Compliant since the installed version is
# still in the allowed list (the base includes v1.9.0).
```

To fully reset the cluster state (remove all GitOps-managed resources):

```bash
# Delete the ApplicationSet (cascades to all apps and managed resources)
oc delete applicationset acm-gitops-demo -n openshift-gitops

# Destroy HCP clusters
hcp destroy cluster kubevirt --name dev-cluster --namespace clusters
hcp destroy cluster kubevirt --name prod-cluster --namespace clusters

# Clean up ClusterSets and namespaces
oc delete managedclusterset dev prod
oc delete namespace dev-policies prod-policies
```

## Kustomize Structure

```
demo-acm-gitops/
├── bootstrap/                        # Manual: oc apply -k bootstrap/
│   ├── 01-gitops-operator.yaml      # GitOps operator + policy namespaces
│   ├── 02-argocd-rbac.yaml          # ClusterRole for ACM/HCP resources
│   ├── 03-root-applicationset.yaml  # Git directory generator
│   └── create-secrets.sh            # HCP cluster secrets helper
├── base/                             # Shared templates (not applied directly)
│   ├── clusters/                    # HostedCluster, NodePool, ClusterSet
│   └── policies/
│       ├── web-terminal/            # OperatorPolicy: fast channel, v1.9.0
│       └── quay/                    # OperatorPolicy: stable-3.17, v3.17.2
└── environments/                     # ArgoCD-managed (auto-discovered)
    ├── dev/
    │   ├── clusters/                # dev-cluster, ClusterSet=dev
    │   └── policies/                # web-terminal + quay → dev-policies ns
    └── prod/
        ├── clusters/                # prod-cluster, ClusterSet=prod
        └── policies/                # web-terminal only → prod-policies ns
```

## Cleanup

```bash
# Remove ArgoCD applications (stops managing resources)
oc delete applicationset acm-gitops-demo -n openshift-gitops

# Remove policies
oc delete policy --all -n dev-policies
oc delete policy --all -n prod-policies

# Destroy HCP clusters
hcp destroy cluster kubevirt --name dev-cluster --namespace clusters
hcp destroy cluster kubevirt --name prod-cluster --namespace clusters

# Remove ClusterSets
oc delete managedclusterset dev prod

# Remove namespaces
oc delete namespace dev-policies prod-policies

# Remove GitOps operator (optional)
oc delete subscription openshift-gitops-operator -n openshift-operators
oc delete csv -n openshift-gitops -l operators.coreos.com/openshift-gitops-operator.openshift-operators
```

## Additional Resources

- [OpenShift GitOps Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/)
- [ArgoCD ApplicationSet Documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/)
- [ACM OperatorPolicy Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.11/html/governance/governance#operator-policy)
- [Hosted Control Planes Documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.11/html/clusters/cluster_mce_overview#hosted-control-planes-intro)
