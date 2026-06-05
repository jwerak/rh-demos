# ACM GitOps: Operator Lifecycle with Dev-to-Prod Promotion

Manage operator installation and upgrades across OpenShift clusters using ArgoCD + ACM OperatorPolicy. This demo provisions HCP clusters, deploys operators (Web Terminal, Quay), and demonstrates git-based promotion from dev to prod.

> For the basic demo without GitOps, see [ACM Operator Lifecycle Management](../demo-acm-policies/README-basic.md).

## Overview

- **GitOps-managed HCP clusters**: ArgoCD provisions dev and prod hosted clusters via HostedCluster CRs
- **ACM OperatorPolicy**: Operators deployed to managed clusters through ACM policy enforcement
- **Dev-to-prod promotion**: Changes go to a demo branch — adding an operator or upgrading a version is a git commit + push
- **ApplicationSet auto-discovery**: ArgoCD automatically discovers environments from the directory structure
- **Easy reset**: Delete the demo branch, recreate from master — ArgoCD reverts everything

## Prerequisites

- **OpenShift Container Platform 4.14+** with ACM/MCE installed
- **OpenShift Virtualization** and **MetalLB** operators installed
- **CLI tools**: `oc`, `kustomize`
- Sufficient cluster resources for 2 HCP clusters (~8 cores + 32GB RAM total)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Git Repository                                                  │
│  branch: demo/acm-gitops (created from master)                   │
│                                                                  │
│  environments/dev/clusters/    environments/prod/clusters/        │
│  environments/dev/policies/    environments/prod/policies/        │
└──────────────────────┬───────────────────────────────────────────┘
                       │ ArgoCD ApplicationSet
                       │ (git directory generator)
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│  Hub Cluster (ArgoCD + ACM)                                      │
│                                                                  │
│  ┌──────────────┐  ┌───────────────┐                             │
│  │  dev-cluster  │  │  prod-cluster  │                            │
│  │  (HCP)        │  │  (HCP)         │                           │
│  │               │  │                │                            │
│  │  Policies:    │  │  Policies:     │                            │
│  │  • Web Term.  │  │  • Web Term.   │                            │
│  │  • Quay       │  │               │                             │
│  └──────────────┘  └───────────────┘                             │
└─────────────────────────────────────────────────────────────────┘
```

## Setup

### 1. Bootstrap GitOps

```bash
# Install GitOps operator, RBAC, and namespaces
oc apply -k bootstrap/

# Wait for the GitOps operator (~2-3 minutes)
watch oc get csv -n openshift-gitops
# Wait for openshift-gitops-operator to reach Succeeded
```

### 2. Create Demo Branch and Deploy ApplicationSet

ArgoCD tracks the `demo/acm-gitops` branch. Create it from master and deploy the ApplicationSet:

```bash
git checkout -b demo/acm-gitops
git push -u origin demo/acm-gitops

# Deploy the ApplicationSet (points to demo/acm-gitops branch)
oc apply -f bootstrap/03-root-applicationset.yaml
```

### 3. Wait for Cluster Provisioning (~15-20 minutes)

```bash
watch oc get hostedclusters -n clusters
# Wait for dev-cluster and prod-cluster to reach PROGRESS=Completed

oc get managedclusters
# dev-cluster    true   https://...   True   True
# prod-cluster   true   https://...   True   True
```

### 4. Verify Initial State

```bash
# Dev: both Web Terminal (v1.9.0) and Quay (v3.17.2)
oc get policy -n dev-policies
# web-terminal    enforce   Compliant
# quay-operator   enforce   Compliant

# Prod: Web Terminal only (v1.9.0)
oc get policy -n prod-policies
# web-terminal    enforce   Compliant
```

## Demo Scenarios

All changes are made on the `demo/acm-gitops` branch. ArgoCD auto-syncs within ~3 minutes of each push.

### Scenario 1: Promote Quay to Production

Add the Quay operator to the prod environment. Edit `environments/prod/policies/kustomization.yaml`:

```diff
 resources:
   - ../../../base/policies/web-terminal
+  - ../../../base/policies/quay
```

Push the change:

```bash
git add environments/prod/policies/kustomization.yaml
git commit -m "Promote Quay operator to production"
git push
```

Verify:

```bash
# Wait for ArgoCD sync (~3 minutes), then check
oc get policy -n prod-policies
# web-terminal    enforce   Compliant
# quay-operator   enforce   Compliant
```

### Scenario 2: Upgrade Web Terminal on Dev (v1.9.0 → v1.14.0)

Expand the allowed versions in the dev overlay to trigger an upgrade. Edit `environments/dev/policies/kustomization.yaml` — change the `Policy` patch to target `web-terminal` by name and add a versions override:

```diff
 patches:
   - target:
       kind: Policy
+      name: web-terminal
     patch: |-
       - op: replace
         path: /metadata/namespace
         value: dev-policies
+      - op: replace
+        path: /spec/policy-templates/0/objectDefinition/spec/versions
+        value:
+          - web-terminal.v1.14.0
+          - web-terminal.v1.13.0
+          - web-terminal.v1.12.1
+          - web-terminal.v1.11.1
+          - web-terminal.v1.11.0
+          - web-terminal.v1.10.1
+          - web-terminal.v1.10.0
+          - web-terminal.v1.9.0
+  - target:
+      kind: Policy
+      name: quay-operator
+    patch: |-
+      - op: replace
+        path: /metadata/namespace
+        value: dev-policies
```

Push the change:

```bash
git add environments/dev/policies/kustomization.yaml
git commit -m "Upgrade web-terminal to v1.14.0 on dev"
git push
```

Monitor the upgrade (~3-5 minutes through the version chain):

```bash
watch oc get policy -n dev-policies
# web-terminal will briefly show NonCompliant during upgrade, then Compliant at v1.14.0

# Check installed version
oc get policy dev-policies.web-terminal -n dev-cluster \
  -o jsonpath='{.status.details[0].history[0].message}' | grep -oE 'web-terminal\.[v0-9.]+'
```

### Scenario 3: Promote Upgrade to Production

Once dev is validated at v1.14.0, apply the same versions patch to `environments/prod/policies/kustomization.yaml`:

```diff
 patches:
   - target:
       kind: Policy
+      name: web-terminal
     patch: |-
       - op: replace
         path: /metadata/namespace
         value: prod-policies
+      - op: replace
+        path: /spec/policy-templates/0/objectDefinition/spec/versions
+        value:
+          - web-terminal.v1.14.0
+          - web-terminal.v1.13.0
+          - web-terminal.v1.12.1
+          - web-terminal.v1.11.1
+          - web-terminal.v1.11.0
+          - web-terminal.v1.10.1
+          - web-terminal.v1.10.0
+          - web-terminal.v1.9.0
```

```bash
git add environments/prod/policies/kustomization.yaml
git commit -m "Promote web-terminal v1.14.0 upgrade to production"
git push
```

## Reset Demo

Delete the demo branch and recreate it from master to return to the starting state:

```bash
git checkout master
git branch -D demo/acm-gitops
git push origin --delete demo/acm-gitops

# Recreate from clean master
git checkout -b demo/acm-gitops
git push -u origin demo/acm-gitops

# ArgoCD auto-syncs back to initial state:
# - Dev: web-terminal v1.9.0 + quay v3.17.2
# - Prod: web-terminal v1.9.0 only
```

> **Note:** OLM does not downgrade operators. After reset, the operators remain at their upgraded versions on the clusters, but the policies will show Compliant since the base version (v1.9.0) is still in the allowed list.

## Full Cleanup

Remove all GitOps-managed resources from the cluster:

```bash
oc delete applicationset acm-gitops-demo -n openshift-gitops

hcp destroy cluster kubevirt --name dev-cluster --namespace clusters
hcp destroy cluster kubevirt --name prod-cluster --namespace clusters

oc delete managedclusterset dev prod
oc delete namespace dev-policies prod-policies clusters

# Remove demo branch
git checkout master
git push origin --delete demo/acm-gitops

# Remove GitOps operator (optional)
oc delete subscription openshift-gitops-operator -n openshift-operators
```

## Kustomize Structure

```
demo-acm-gitops/
├── bootstrap/                        # Manual: oc apply -k bootstrap/
│   ├── 01-gitops-operator.yaml      # GitOps operator + policy namespaces
│   ├── 02-argocd-rbac.yaml          # ClusterRole for ACM/HCP resources
│   ├── 03-root-applicationset.yaml  # Git directory generator (tracks demo/acm-gitops branch)
│   └── create-secrets.sh            # HCP cluster secrets helper (fallback)
├── base/                             # Shared templates (not applied directly)
│   ├── clusters/                    # HostedCluster, NodePool, ClusterSet, pull secret
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

## Additional Resources

- [OpenShift GitOps Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/)
- [ArgoCD ApplicationSet Documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/)
- [ACM OperatorPolicy Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.11/html/governance/governance#operator-policy)
- [Hosted Control Planes Documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.11/html/clusters/cluster_mce_overview#hosted-control-planes-intro)
