# ACM Operator Policies - Kustomize Structure

This directory contains ACM policies for managing operator lifecycle across managed clusters using a kustomize-based structure.

## Directory Structure

Each operator has its own subdirectory following this pattern:

```
operators/
└── <operator-name>/
    ├── base/                          # Common policy components
    │   ├── policy.yaml               # OperatorPolicy definition
    │   ├── placement.yaml            # Cluster targeting rules
    │   ├── placementbinding.yaml     # Binds policy to placement
    │   └── kustomization.yaml        # Base kustomize config
    └── overlays/                      # Environment-specific variations
        ├── initial/                   # Initial deployment version
        │   └── kustomization.yaml
        └── updated/                   # Upgrade configuration
            └── kustomization.yaml    # Inline JSON 6902 patches
```

## Available Operators

### web-terminal

Manages the Web Terminal operator lifecycle across development clusters.

**Deploy initial version (v1.9.0):**
```bash
kustomize build operators/web-terminal/overlays/initial/ | oc apply -f -
```

**Upgrade to v1.10.1:**
```bash
kustomize build operators/web-terminal/overlays/updated/ | oc apply -f -
```

**View generated manifests:**
```bash
kustomize build operators/web-terminal/overlays/initial/
kustomize build operators/web-terminal/overlays/updated/
```

## Adding a New Operator

To add a new operator policy:

1. **Create directory structure:**
   ```bash
   mkdir -p operators/<operator-name>/{base,overlays/{initial,updated}}
   ```

2. **Create base files** in `operators/<operator-name>/base/`:
   - `policy.yaml` - Define OperatorPolicy with initial version
   - `placement.yaml` - Define cluster targeting
   - `placementbinding.yaml` - Bind policy to placement
   - `kustomization.yaml` - List resources

3. **Create initial overlay** in `overlays/initial/`:
   - `kustomization.yaml` - Reference base

4. **Create updated overlay** in `overlays/updated/`:
   - `kustomization.yaml` - Reference base and define inline JSON 6902 patches for version upgrades and enforcement changes

## Key Concepts

### Base
Contains the common components shared across all overlays. Defines:
- The operator to manage (`subscription.name`)
- The source catalog (`source`, `sourceNamespace`)
- The update channel (`channel`)
- Default behavior (`remediationAction`, `upgradeApproval`)

### Overlays
Environment-specific or version-specific customizations:

- **initial**: Fresh deployment, typically with:
  - `remediationAction: inform` (audit mode)
  - Single version in `versions` array
  - Specific `startingCSV`

- **updated**: Upgrade configuration, typically with:
  - `remediationAction: enforce` (active enforcement)
  - Expanded `versions` array with upgrade path
  - Same `startingCSV` as initial

### Patches

This structure uses **JSON 6902 patches** (inline in kustomization.yaml) for surgical precision:

```yaml
patches:
  - target:
      kind: Policy
      name: web-terminal
    patch: |-
      - op: replace
        path: /spec/policy-templates/0/objectDefinition/spec/remediationAction
        value: enforce
      - op: replace
        path: /spec/policy-templates/0/objectDefinition/spec/versions
        value: [...]
```

**Benefits over strategic merge:**
- ✅ No field duplication - only patch what changes
- ✅ Explicit operations (`replace`, `add`, `remove`)
- ✅ Modern approach (strategic merge is deprecated)
- ✅ Clearer intent - see exactly what's being modified

## Best Practices

1. **Version Pinning**: Always specify `startingCSV` in base to ensure consistent initial deployments
2. **Upgrade Paths**: Include all intermediate versions in the `versions` array for smooth upgrades
3. **Audit First**: Use `remediationAction: inform` initially to validate before enforcing
4. **Cluster Sets**: Target specific cluster sets (e.g., `development`, `production`) for controlled rollouts
5. **Documentation**: Add comments in patches explaining why specific versions are included

## Troubleshooting

**Policy not compliant:**
```bash
# Check policy status
oc get policy -n development-policies

# View detailed status
oc describe policy web-terminal -n development-policies
```

**Operator stuck at old version:**
```bash
# Check ClusterServiceVersion on managed cluster
oc get csv -n openshift-operators

# View subscription status
oc get subscription -n openshift-operators
```

**Kustomize build fails:**
```bash
# Validate kustomization
kustomize build operators/<operator-name>/overlays/<overlay-name> --validate

# Check for syntax errors in YAML
yamllint operators/<operator-name>/
```

## Resources

- [ACM OperatorPolicy Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.11/html/governance/governance#operator-policy)
- [Kustomize Documentation](https://kubectl.docs.kubernetes.io/references/kustomize/)
- [OpenShift Operator Lifecycle Manager](https://docs.openshift.com/container-platform/latest/operators/understanding/olm/olm-understanding-olm.html)
