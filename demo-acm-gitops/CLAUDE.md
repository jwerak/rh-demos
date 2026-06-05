# CLAUDE.md

ACM GitOps demo: manage operator lifecycle across OpenShift clusters using ArgoCD + ACM OperatorPolicy with dev-to-prod promotion.

## Key Commands

```bash
# Bootstrap: install GitOps operator, RBAC, ApplicationSet
oc apply -k bootstrap/

# Create secrets for a cluster (before ArgoCD can provision it)
./bootstrap/create-secrets.sh dev-cluster
./bootstrap/create-secrets.sh prod-cluster

# Check ArgoCD applications
oc get applications.argoproj.io -n openshift-gitops

# Check HCP clusters
oc get hostedclusters -n clusters

# Check policy compliance
oc get policy -n dev-policies
oc get policy -n prod-policies

# Promote Quay to prod: add quay base to prod policies overlay, commit, push
# ArgoCD auto-syncs the change
```

## Kustomize Structure

```
base/
  clusters/          HostedCluster, NodePool, ManagedClusterSet templates
  policies/
    web-terminal/    OperatorPolicy for Web Terminal (fast channel)
    quay/            OperatorPolicy for Quay (stable-3.17)
environments/
  dev/
    clusters/        Patches: name=dev-cluster, clusterset=dev
    policies/        Both web-terminal + quay, namespace=dev-policies
  prod/
    clusters/        Patches: name=prod-cluster, clusterset=prod
    policies/        Web-terminal only initially (quay added via promotion)
bootstrap/           GitOps operator, RBAC, ApplicationSet, secrets helper
```

Overlays use JSON 6902 patches to replace placeholder values (CLUSTER_NAME, CLUSTER_SET, POLICY_NAMESPACE) from base templates.

## Promotion Flow

1. Dev has both operators. Prod has web-terminal only.
2. To promote Quay to prod: add `../../../base/policies/quay` to `environments/prod/policies/kustomization.yaml`
3. Commit and push — ArgoCD auto-syncs

## Tools Required

`oc`, `kustomize` (or `oc apply -k`). ArgoCD is installed as part of the bootstrap.

## Related

- Basic ACM demo (no GitOps): `../demo-acm-policies/README-basic.md`
