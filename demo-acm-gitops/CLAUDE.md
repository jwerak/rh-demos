# CLAUDE.md

ACM GitOps demo: manage operator lifecycle across OpenShift clusters using ArgoCD + ACM OperatorPolicy with dev-to-prod promotion.

## Key Commands

```bash
# Bootstrap: install GitOps operator, RBAC
oc apply -k bootstrap/

# Create demo branch and deploy ApplicationSet
git checkout -b demo/acm-gitops && git push -u origin demo/acm-gitops
oc apply -f bootstrap/03-root-applicationset.yaml

# Check ArgoCD applications
oc get applications.argoproj.io -n openshift-gitops

# Check policy compliance
oc get policy -n dev-policies
oc get policy -n prod-policies

# Reset demo: delete branch, recreate from master
git checkout master && git push origin --delete demo/acm-gitops
git checkout -b demo/acm-gitops && git push -u origin demo/acm-gitops
```

## Kustomize Structure

```
base/
  clusters/          HostedCluster, NodePool, ManagedClusterSet, pull secret
  policies/
    web-terminal/    OperatorPolicy for Web Terminal (fast channel, v1.9.0)
    quay/            OperatorPolicy for Quay (stable-3.17, v3.17.2)
    branding/        ConfigurationPolicy: ConsoleNotification banner per environment
environments/
  dev/
    clusters/        Patches: name=dev-cluster, clusterset=dev
    policies/        web-terminal + quay + branding (green "DEV ENVIRONMENT")
  prod/
    clusters/        Patches: name=prod-cluster, clusterset=prod
    policies/        web-terminal + branding (red "PRODUCTION ENVIRONMENT")
bootstrap/           GitOps operator, RBAC, ApplicationSet (tracks demo/acm-gitops branch)
```

## Branch Strategy

Master holds the base state. Demo work happens on the `demo/acm-gitops` branch. ApplicationSet tracks this branch. Reset = delete branch, recreate from master.

## Demo Scenarios

1. **Promote Quay to prod**: add `../../../base/policies/quay` to prod overlay resources
2. **Upgrade web-terminal on dev**: expand versions array in dev overlay patch (v1.9.0 → v1.14.0)
3. **Promote upgrade to prod**: copy same versions patch to prod overlay

## Tools Required

`oc`, `kustomize`, `git`. ArgoCD is installed as part of the bootstrap.

## Related

- Basic ACM demo (no GitOps): `../demo-acm-policies/README-basic.md`
