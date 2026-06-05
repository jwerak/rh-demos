# CLAUDE.md

ACM OperatorPolicy demo: manage operator install, upgrade, and removal across OpenShift clusters. Uses Web Terminal operator as the example.

## Key Commands

```bash
# Query available operator versions (fast channel)
oc get packagemanifests.packages.operators.coreos.com -n openshift-marketplace web-terminal \
  -o jsonpath='{range .status.channels[?(@.name=="fast")].entries[*]}- {.name}{"\n"}{end}' | sort -V

# Install operator pinned to v1.9.0
kustomize build operators/web-terminal/overlays/initial/ | oc apply -f -

# Upgrade to v1.12.1 (expands allowed versions list)
kustomize build operators/web-terminal/overlays/updated/ | oc apply -f -

# Remove operator via policy (complianceType: mustnothave)
kustomize build operators/web-terminal/overlays/removed/ | oc apply -f -

# Check policy compliance
oc get policy -n development-policies
```

## Kustomize Structure

```
operators/web-terminal/
  base/              policy.yaml, placement.yaml, placementbinding.yaml
  overlays/
    initial/         Enforce mode, single version (v1.9.0) - fresh install
    updated/         Enforce mode, expanded versions array - triggers upgrade
    removed/         Changes complianceType to mustnothave, adds removalBehavior
```

Overlays use inline JSON 6902 patches (not strategic merge). Base defines the operator subscription, catalog source, channel, and default inform mode.

## Other Directories

- `files/` - Legacy standalone policy YAMLs (prefer kustomize overlays instead)
- `policy-generator/` - ACM PolicyGenerator kustomize plugin examples
- `red-hat-icons/` - Icons used in video/presentation materials

## Tools Required

`oc`, `kustomize` (or `oc apply -k`). Policies target namespace `development-policies` and ClusterSet `development`.

## Notes

- Czech translation exists in `README-cs.md`
- See `operators/README.md` for instructions on adding new operators
- Video demo: `acm-operator-demo.mp4`; generation script: `make_video.py`
