# ACM Operator Lifecycle Management

Manage operator installation and upgrades across OpenShift clusters using Red Hat Advanced Cluster Management (ACM) OperatorPolicy.

## Demo Options

### [Basic: Direct Policy Management](README-basic.md)

Apply ACM policies directly with `oc apply -k`. Best for learning the OperatorPolicy pattern — install, upgrade, and remove operators on managed clusters using kustomize overlays.

### [GitOps: ArgoCD-Managed Policies with Dev/Prod Promotion](../demo-acm-gitops/README.md)

Full GitOps workflow using OpenShift GitOps (ArgoCD). Provisions HCP clusters, deploys operator policies (Web Terminal + Quay), and demonstrates dev-to-prod promotion via git-based workflow. Includes ApplicationSet auto-discovery of environments.
