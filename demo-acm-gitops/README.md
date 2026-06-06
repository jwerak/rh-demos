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

```txt
┌──────────────────────────────────────────────────────────────────┐
│  Git Repository                                                  │
│  branch: demo/<your-id> (created from master)                    │
│                                                                  │
│  environments/dev/clusters/    environments/prod/clusters/       │
│  environments/dev/policies/    environments/prod/policies/       │
└──────────────────────┬───────────────────────────────────────────┘
                       │ ArgoCD ApplicationSet
                       │ (git directory generator)
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│  Hub Cluster (ArgoCD + ACM)                                     │
│                                                                 │
│  ┌──────────────┐  ┌───────────────┐                            │
│  │  dev-cluster │  │  prod-cluster │                            │
│  │  (HCP)       │  │  (HCP)        │                            │
│  │              │  │               │                            │
│  │  Policies:   │  │  Policies:    │                            │
│  │  • Web Term. │  │  • Web Term.  │                            │
│  │  • Quay      │  │               │                            │
│  └──────────────┘  └───────────────┘                            │
└─────────────────────────────────────────────────────────────────┘
```

## Setup

### 1. Choose a Demo ID

Pick a unique ID for your demo session (e.g., your name or team). This allows multiple demos to run in parallel on the same cluster:

```bash
export DEMO_ID=alice   # change this to your name/id
export BASE_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
```

### 2. Bootstrap GitOps

```bash
# Install GitOps operator, RBAC, and namespaces (shared, run once per cluster) using Kustomize
oc apply -k bootstrap/

# Copy the hub pull secret to the clusters namespace (required for HCP provisioning)
oc get secret pull-secret -n openshift-config -o json \
  | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp) | .metadata.name = "hcp-pull-secret"' \
  | oc apply -n clusters -f -

# Wait for the GitOps operator (~2-3 minutes)
watch oc get csv -n openshift-gitops
# Wait for openshift-gitops-operator to reach Succeeded
```

### 3. Create Demo Branch and Deploy ApplicationSet

Each demo session uses its own branch. The ApplicationSet template has `DEMO_BRANCH` and `DEMO_ID` placeholders that get replaced with your values. The `BASE_DOMAIN` placeholder in the HostedCluster template is replaced on the branch so ArgoCD picks up the correct hub ingress domain:

```bash
# Create your demo branch from master
git checkout -b "demo/${DEMO_ID}"

# Set the hub cluster's base domain in the HostedCluster template
sed -i "s|BASE_DOMAIN|${BASE_DOMAIN}|g" base/clusters/hostedcluster.yaml
git add base/clusters/hostedcluster.yaml
git commit -m "Set base domain to ${BASE_DOMAIN}"
git push -u origin "demo/${DEMO_ID}"

# Deploy ApplicationSet with your branch and ID
sed "s|DEMO_BRANCH|demo/${DEMO_ID}|g; s|DEMO_ID|${DEMO_ID}|g" \
  bootstrap/03-root-applicationset.yaml | oc apply -f -

# Verify — your apps will be prefixed with your DEMO_ID
oc get applications.argoproj.io -n openshift-gitops -l "app.kubernetes.io/instance=${DEMO_ID}"
```

### 4. Wait for Cluster Provisioning (~15-20 minutes)

```bash
watch oc get hostedclusters -n clusters
# Wait for dev-cluster and prod-cluster to reach PROGRESS=Completed

oc get managedclusters
# dev-cluster    true   https://...   True   True
# prod-cluster   true   https://...   True   True
```

### 5. Verify Initial State

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

All changes are made on the `demo/${DEMO_ID}` branch. ArgoCD auto-syncs within ~3 minutes of each push. Complete scenario files are in `scenarios/` — just copy them over.

### Scenario 1: Promote Quay to Production

Add the Quay operator to the prod environment:

```bash
cp scenarios/scenario-1-quay-to-prod/kustomization.yaml environments/prod/policies/kustomization.yaml
git add environments/prod/policies/kustomization.yaml
git commit -m "Promote Quay operator to production"
git push
```

Verify (~3 minutes for ArgoCD sync):

```bash
oc get policy -n prod-policies
# web-terminal           enforce   Compliant
# quay-operator          enforce   Compliant
# environment-branding   enforce   Compliant
```

### Scenario 2: Upgrade Web Terminal on Dev (v1.9.0 → v1.12.1)

Expand the allowed versions to include the full upgrade path from v1.9.0 through v1.12.1 (all intermediate versions from the `fast` channel):

```bash
cp scenarios/scenario-2-web-term-1.12.1-dev/kustomization.yaml environments/dev/policies/kustomization.yaml
git add environments/dev/policies/kustomization.yaml
git commit -m "Upgrade web-terminal to v1.12.1 on dev"
git push
```

Monitor the upgrade (~3-5 minutes through the version chain v1.9.0 → v1.10.x → v1.11.x → v1.12.1):

```bash
watch oc get policy -n dev-policies
# web-terminal will briefly show NonCompliant during upgrade, then Compliant at v1.12.1

# Check installed version
oc get policy dev-policies.web-terminal -n dev-cluster \
  -o jsonpath='{.status.details[0].history[0].message}' | grep -oE 'web-terminal\.[v0-9.]+'
```

> **Note:** The versions array must include ALL intermediate versions (including pre-release `.p` builds) so OLM can traverse the upgrade graph. These can be listed with:
> ```bash
> oc get packagemanifests -n openshift-marketplace web-terminal \
>   -o jsonpath='{range .status.channels[?(@.name=="fast")].entries[*]}- {.name}{"\n"}{end}' | sort -V
> ```

### Scenario 3: Promote Upgrade to Production

Once dev is validated at v1.12.1, apply the same upgrade to prod:

```bash
cp scenarios/scenario-3-web-term-1.12.1-prod/kustomization.yaml environments/prod/policies/kustomization.yaml
git add environments/prod/policies/kustomization.yaml
git commit -m "Promote web-terminal v1.12.1 upgrade to production"
git push
```

## Reset Demo

Delete the demo branch and recreate it from master to return to the starting state:

```bash
git checkout master
git branch -D "demo/${DEMO_ID}"
git push origin --delete "demo/${DEMO_ID}"

# Recreate from clean master
git checkout -b "demo/${DEMO_ID}"
git push -u origin "demo/${DEMO_ID}"

# ArgoCD auto-syncs back to initial state:
# - Dev: web-terminal v1.9.0 + quay v3.17.2 + green banner
# - Prod: web-terminal v1.9.0 + red banner (no Quay)
```

> **Note:** OLM does not downgrade operators. After reset, the operators remain at their upgraded versions on the clusters, but the policies will show Compliant since the base version (v1.9.0) is still in the allowed list.

## Full Cleanup

Remove all GitOps-managed resources from the cluster:

```bash
# Remove your ApplicationSet (cascades to all apps)
oc delete applicationset "${DEMO_ID}-acm-gitops" -n openshift-gitops

# Destroy HCP clusters
hcp destroy cluster kubevirt --name dev-cluster --namespace clusters
hcp destroy cluster kubevirt --name prod-cluster --namespace clusters

# Clean up
oc delete managedclusterset dev prod
oc delete namespace dev-policies prod-policies

# Remove demo branch
git checkout master
git push origin --delete "demo/${DEMO_ID}"

# Remove GitOps operator (optional, shared resource)
oc delete subscription openshift-gitops-operator -n openshift-operators
```

## Kustomize Structure

```
demo-acm-gitops/
├── bootstrap/                        # Manual: oc apply -k bootstrap/
│   ├── 01-gitops-operator.yaml      # GitOps operator + policy namespaces
│   ├── 02-argocd-rbac.yaml          # ClusterRole for ACM/HCP resources
│   ├── 03-root-applicationset.yaml  # Git directory generator (DEMO_BRANCH/DEMO_ID placeholders)
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
