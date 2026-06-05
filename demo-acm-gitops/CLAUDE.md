# CLAUDE.md

ACM GitOps demo: manage operator lifecycle across OpenShift clusters using ArgoCD + ACM OperatorPolicy with dev-to-prod promotion.

## Key Commands

```bash
export DEMO_ID=alice  # unique per user, enables parallel demos

# Bootstrap (shared, once per cluster)
oc apply -k bootstrap/
oc get secret pull-secret -n openshift-config -o json \
  | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp) | .metadata.name = "hcp-pull-secret"' \
  | oc apply -n clusters -f -

# Create demo branch and deploy ApplicationSet
git checkout -b "demo/${DEMO_ID}" && git push -u origin "demo/${DEMO_ID}"
sed "s|DEMO_BRANCH|demo/${DEMO_ID}|g; s|DEMO_ID|${DEMO_ID}|g" \
  bootstrap/03-root-applicationset.yaml | oc apply -f -

# Check ArgoCD applications (prefixed with DEMO_ID)
oc get applications.argoproj.io -n openshift-gitops

# Reset demo: delete branch, recreate from master
git checkout master && git push origin --delete "demo/${DEMO_ID}"
git checkout -b "demo/${DEMO_ID}" && git push -u origin "demo/${DEMO_ID}"
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

Master holds the base state. Each user creates `demo/<id>` branch. ApplicationSet template uses `DEMO_BRANCH` and `DEMO_ID` placeholders replaced via `sed` at deploy time. Multiple users can run in parallel with unique IDs. Reset = delete branch, recreate from master.

## Demo Scenarios

1. **Promote Quay to prod**: add `../../../base/policies/quay` to prod overlay resources
2. **Upgrade web-terminal on dev**: expand versions array in dev overlay patch (v1.9.0 → v1.14.0)
3. **Promote upgrade to prod**: copy same versions patch to prod overlay

## Tools Required

`oc`, `kustomize`, `git`. ArgoCD is installed as part of the bootstrap.

## Related

- Basic ACM demo (no GitOps): `../demo-acm-policies/README-basic.md`
