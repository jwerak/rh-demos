# VM Self-Service Portal — Demo Guide

Self-service VM portal: RHDH 1.10 + GitLab CE + ArgoCD + OpenShift Virtualization + Gatekeeper OPA.

## Access URLs

After deployment (`./scripts/deploy.sh`):

```bash
source .env

# Portal
echo "RHDH:     https://backstage-rhdh.${BASE_DOMAIN}"
echo "GitLab:   https://gitlab.${BASE_DOMAIN}"
echo "Keycloak: https://keycloak.${BASE_DOMAIN}"
echo "ArgoCD:   https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
```

**Demo users** (login via Keycloak OIDC in RHDH):

| User | Password | Role | Can do |
|------|----------|------|--------|
| `vm-requestor` | `$DEMO_PASSWORD` | requestor | Create VM requests |
| `app-owner` | `$DEMO_PASSWORD` | approver | Approve MRs in GitLab |
| `security-admin` | `$DEMO_PASSWORD` | approver | Approve MRs in GitLab |
| `platform-admin` | `$DEMO_PASSWORD` | admin | Full RHDH access, RBAC management |

**GitLab admin**: `root` / `$GITLAB_ADMIN_PASSWORD`
**ArgoCD admin**: `admin` / `oc extract secret/openshift-gitops-cluster -n openshift-gitops --to=- --keys=admin.password 2>/dev/null`

---

## Two Catalog Items — Two Enforcement Mechanisms

The portal has two VM creation templates, each demonstrating a different governance model:

| Template | Enforcement | How it works |
|----------|-------------|--------------|
| **Create Virtual Machine** | MR-based approval (humans review) | Creates GitLab MR → app-owner + security-admin approve → merge → ArgoCD syncs → VM created |
| **Create VM (Policy Test)** | Gatekeeper OPA (automated policy) | Publishes directly to main → ArgoCD syncs immediately → Gatekeeper webhook allows or denies |

---

## Demo Scenario A: MR-Based Approval (Create Virtual Machine)

Shows the human approval workflow — two approvers must review and merge before the VM is provisioned.

### Steps

1. **Login to RHDH** as `vm-requestor`
2. Go to **Create** → select **Create Virtual Machine**
3. Fill in the form:
   - VM Name: `dev-web-01` (must match `prefix-name-number` format)
   - CPU: 2, Memory: 4 GiB, Disk: 20 GiB
   - OS Image: RHEL 9, Environment: Development
   - Owner: pick `vm-requestor`, Cost Center: CC-001
4. Click **Create** — RHDH creates a GitLab repo and opens a Merge Request
5. **Show the MR** — click the "Merge Request" link in the output
   - The MR description shows a summary table of all requested parameters
   - The MR diff shows the VM manifests (VirtualMachine, Service, Secret)
6. **Login to GitLab** as `app-owner` → approve the MR
7. **Login to GitLab** as `security-admin` → approve and merge the MR
8. **Show ArgoCD** — within 30 seconds, ArgoCD discovers the new repo and syncs the VM
9. **Verify**: `oc get vm -n vm-dev` — the VM is Running

### What to highlight

- Git is the single source of truth — all changes go through Git
- Two-person approval — no single person can provision a VM alone
- Full audit trail in Git history — who requested, who approved, when

---

## Demo Scenario B: Gatekeeper Policy Enforcement (Create VM — Policy Test)

Shows automated policy-as-code — Gatekeeper OPA blocks non-compliant VMs at the Kubernetes API level. No human approval needed; the policies enforce compliance automatically.

### Three Policies in Effect

| Policy | Rule | Example violation |
|--------|------|-------------------|
| Naming convention | Name must match `^[a-z]{2,4}-[a-z]+-[0-9]{2}$` | `badname`, `my-super-long-vm`, `toolong-name-999` |
| Resource limits | Max 8 CPU, 16 GiB RAM, 100 GiB disk | 32 cores, 64 GiB RAM |
| Required labels | Must have `managed-by`, `environment`, `cost-center` | Unchecking "Include required labels" |

### Steps — Valid VM (passes all policies)

1. **Login to RHDH** as `vm-requestor`
2. Go to **Create** → select **Create VM (Policy Test)**
3. Fill in compliant values:
   - VM Name: `dev-web-01`
   - CPU: 2, Memory: 4, Disk: 20
   - Labels: checked (default)
4. Click **Create** — repo is created and pushed directly to `main`
5. **Open ArgoCD UI** → find application `vm-dev-web-01`
   - Status: **Synced** ✅ — Gatekeeper allowed the VM
6. **Verify**: `oc get vm dev-web-01 -n vm-dev` — VM is Running

### Steps — Invalid VM (blocked by Gatekeeper)

1. **Login to RHDH** as `vm-requestor`
2. Go to **Create** → select **Create VM (Policy Test)**
3. Fill in non-compliant values:
   - VM Name: `badname` (violates naming convention)
   - CPU: **32** (violates max 8 limit)
   - Memory: **64** (violates max 16 limit)
   - Disk: **200** (violates max 100 limit)
   - **Uncheck** "Include required labels" (violates required labels policy)
4. Click **Create** — repo is created and pushed to `main`
5. **RHDH shows success** — it only created the Git repo, which succeeded
6. **Now open ArgoCD UI** to see the denial:

   ```
   ArgoCD URL → Applications → vm-badname
   ```

   - Sync Status: **OutOfSync** ❌
   - Click the application → **SYNC RESULT** tab shows:

   ```
   admission webhook "validation.gatekeeper.sh" denied the request:
   [vm-naming] VM name 'badname' does not match naming convention...
   [vm-resource-limits] VM CPU cores 32 exceeds maximum allowed 8
   [vm-resource-limits] VM memory 64Gi exceeds maximum allowed 16Gi
   [vm-resource-limits] VM disk size 200Gi exceeds maximum allowed 100Gi
   [vm-required-labels] VM is missing required label 'app.kubernetes.io/managed-by'
   [vm-required-labels] VM is missing required label 'cost-center'
   [vm-required-labels] VM is missing required label 'environment'
   ```

7. **Verify no VM was created**: `oc get vm badname -n vm-dev` → not found

### Where to See the Denial

The denial is **not visible in RHDH** — RHDH only tracks the Git repo creation (which succeeded). The Gatekeeper denial happens when ArgoCD tries to sync the manifest to the cluster.

**See it here:**

| Where | How |
|-------|-----|
| **ArgoCD UI** | Applications → `vm-<name>` → Sync Status shows OutOfSync, click for error details |
| **CLI** | `oc get application vm-<name> -n openshift-gitops -o yaml \| grep -A 20 operationState` |
| **CLI (short)** | `oc get applications -n openshift-gitops` — look for `OutOfSync` status |

### Steps — Fix a Violation (Exception Workflow)

1. After seeing the denial in ArgoCD, **go to GitLab** → `vm-instances/badname` repo
2. Edit `vm-manifests/virtualmachine.yaml`:
   - Fix the name to `dev-fix-01`
   - Reduce CPU to 2, memory to 4Gi, disk to 20Gi
   - Add the missing labels
3. Commit the fix (or create a new MR)
4. ArgoCD detects the change and retries sync
5. Gatekeeper allows the corrected manifest → VM is created

---

## Demo: Audit Existing Violations

Gatekeeper's audit controller periodically scans existing resources and reports violations — even for VMs that were created before the policies were deployed.

```bash
# See which constraints have violations
oc get constraints -o custom-columns='NAME:.metadata.name,ENFORCEMENT:.spec.enforcementAction,VIOLATIONS:.status.totalViolations'

# See violation details for naming policy
oc get vmnamingconvention vm-naming -o jsonpath='{range .status.violations[*]}{.name}{" -> "}{.message}{"\n"}{end}'
```

Audit does NOT delete or block existing VMs — it only reports them. The admission webhook blocks new CREATE/UPDATE requests.

---

## Demo: Direct CLI Test

Quick way to demonstrate policy enforcement without going through RHDH:

```bash
# This VM violates naming + labels policies — Gatekeeper blocks it
cat <<'EOF' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: badname
  namespace: vm-dev
  labels:
    app: badname
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/domain: badname
    spec:
      domain:
        cpu:
          cores: 1
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
        resources:
          requests:
            memory: 1Gi
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          emptyDisk:
            capacity: 1Gi
EOF
# Expected: admission webhook "validation.gatekeeper.sh" denied the request
```

---

## Cleanup

```bash
# Delete a test VM repo from GitLab (triggers ArgoCD prune)
source .env
curl -ks -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://gitlab.${BASE_DOMAIN}/api/v4/projects/vm-instances%2F<vm-name>"

# Or delete the ArgoCD application directly
oc delete application vm-<name> -n openshift-gitops

# Full teardown
./scripts/teardown.sh
```

---

## Architecture

```
                  ┌────────────────────────────────┐
                  │         RHDH Portal             │
                  │    (Software Templates)         │
                  └──────────┬─────────────────────┘
                             │ publish:gitlab
                             ▼
                  ┌────────────────────────────────┐
                  │       GitLab CE (on-cluster)    │
                  │    vm-instances/<vm-name>       │
                  └──────────┬─────────────────────┘
                             │ SCM Provider (30s poll)
                             ▼
                  ┌────────────────────────────────┐
                  │     ArgoCD ApplicationSet       │
                  │  discovers new repos, syncs     │
                  └──────────┬─────────────────────┘
                             │ oc apply (VirtualMachine CR)
                             ▼
              ┌──────────────────────────────────────────┐
              │          Kubernetes API Server            │
              │                                          │
              │  ┌────────────────────────────────────┐  │
              │  │    Gatekeeper Admission Webhook     │  │
              │  │                                    │  │
              │  │  ✓ Naming: prefix-name-number      │  │
              │  │  ✓ Resources: ≤8 CPU, ≤16Gi, ≤100Gi│  │
              │  │  ✓ Labels: managed-by, env, cost   │  │
              │  └────────────┬───────────────────────┘  │
              │               │                          │
              │         ALLOW │ DENY                     │
              └───────────────┼──────────────────────────┘
                     ┌────────┴────────┐
                     ▼                 ▼
              VM Created          ArgoCD SyncFailed
              (Running)           (error message)
```
