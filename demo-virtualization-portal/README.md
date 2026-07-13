# VM Self-Service Portal — Demo Guide

Self-service VM portal: RHDH 1.10 + GitLab CE + ArgoCD + OpenShift Virtualization + Gatekeeper OPA.

## Prerequisites

### Cluster Requirements

- **OpenShift 4.14+** with cluster-admin access
- **OpenShift Virtualization** operator installed and configured (HyperConverged CR deployed)
- At least one DataSource in `openshift-virtualization-os-images` namespace (e.g. `rhel9`, `rhel8`, `fedora`)
- Sufficient cluster resources: GitLab alone requires 4 CPU / 8 GiB RAM

### Tools

| Tool | Purpose |
|------|---------|
| `oc` | OpenShift CLI (logged in as cluster-admin) |
| `curl` | GitLab API calls (seed-gitlab.sh) |
| `htpasswd` | Demo user creation (create-demo-users.sh) — from `httpd-tools` |
| `git` | Push templates to GitLab |
| `openssl` | Generate secrets if not provided |
| `python3` | Parse Keycloak API responses |

### DNS Setup

Create a wildcard A record: `*.<base-domain>` → OpenShift router IP.

To find the router IP:
```bash
dig +short console-openshift-console.$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
```

**NOTE**: Do NOT use CNAME to `apps.<cluster>` — the bare apps domain has no A record. Use an A record instead.

The following subdomains will be created:
- `backstage-rhdh.<base-domain>` — RHDH portal
- `gitlab.<base-domain>` — GitLab CE
- `keycloak.<base-domain>` — Keycloak SSO

---

## Deployment

### 1. Configure Environment

```bash
cd demo-virtualization-portal
cp .env.sample .env
# Edit .env with your values — all variables are required
vi .env
source .env
```

| Variable | Description | Example |
|----------|-------------|---------|
| `BASE_DOMAIN` | Custom domain for routes (wildcard DNS must point to router) | `virt-portal.example.com` |
| `GITLAB_ADMIN_PASSWORD` | GitLab root password | `MySecurePass123` |
| `GITLAB_TOKEN` | GitLab PAT for RHDH (must start with `glpat-`) | `glpat-rhdh-portal-token` |
| `BACKEND_SECRET` | RHDH backend auth secret | `openssl rand -base64 32` |
| `DEMO_PASSWORD` | Password for Keycloak demo users | `DemoPass123` |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak admin password | `KcAdmin123` |
| `KEYCLOAK_CLIENT_SECRET` | OIDC client secret for RHDH | any random string |
| `GITHUB_REPO` | This repo's Git URL (for ArgoCD) | `https://github.com/user/rh-demos.git` |
| `GIT_REVISION` | Git branch for ArgoCD | `master` |

### 2. Deploy

```bash
./scripts/deploy.sh
```

The script runs 7 phases:

| Phase | What it does | Duration |
|-------|-------------|----------|
| 0 | Verify `oc login` | instant |
| 1 | Install OpenShift GitOps Operator + RBAC | ~2 min |
| 2 | Deploy RHDH Operator via ArgoCD | ~3 min |
| 3 | Deploy GitLab CE (on-cluster) | ~5 min |
| 3b | Deploy Keycloak + configure OIDC | ~2 min |
| 4 | Deploy RHDH (Backstage CR + config) | ~3 min |
| 5 | Seed GitLab (PAT, groups, users, templates) | ~1 min |
| 6 | Deploy demo environments + VM ApplicationSet | instant |
| 7 | Install Gatekeeper OPA + policies | ~3 min |

Total: ~20 minutes on a healthy cluster.

### 3. (Optional) Create OpenShift Demo Users

If you want htpasswd-based users in OpenShift (separate from Keycloak users):

```bash
./scripts/create-demo-users.sh
```

### 4. Verify

```bash
source .env

# Check ArgoCD applications
oc get applications.argoproj.io -n openshift-gitops

# Check RHDH
oc get backstage -n rhdh

# Check demo namespaces
oc get ns | grep vm-

# Check Gatekeeper
oc get constraints
```

---

## Access URLs

```bash
source .env
echo "RHDH:     https://backstage-rhdh.${BASE_DOMAIN}"
echo "GitLab:   https://gitlab.${BASE_DOMAIN}"
echo "Keycloak: https://keycloak.${BASE_DOMAIN}"
echo "ArgoCD:   https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
```

**Demo users** (login via Keycloak OIDC in RHDH):

| User             | Password         | Role      | Can do                            |
| ---------------- | ---------------- | --------- | --------------------------------- |
| `vm-requestor`   | `$DEMO_PASSWORD` | requestor | Create VM requests                |
| `app-owner`      | `$DEMO_PASSWORD` | approver  | Approve MRs in GitLab             |
| `security-admin` | `$DEMO_PASSWORD` | approver  | Approve MRs in GitLab             |
| `platform-admin` | `$DEMO_PASSWORD` | admin     | Full RHDH access, RBAC management |

**GitLab admin**: `root` / `$GITLAB_ADMIN_PASSWORD`
**ArgoCD admin**: `admin` / `oc extract secret/openshift-gitops-cluster -n openshift-gitops --to=- --keys=admin.password 2>/dev/null`

---

## Two Catalog Items — Two Enforcement Mechanisms

The portal has two VM creation templates, each demonstrating a different governance model:

| Template                       | Enforcement                       | How it works                                                                                |
| ------------------------------ | --------------------------------- | ------------------------------------------------------------------------------------------- |
| **Create Virtual Machine**     | MR-based approval (humans review) | Creates GitLab MR → app-owner + security-admin approve → merge → ArgoCD syncs → VM created  |
| **Resize Virtual Machine**     | MR-based approval (humans review) | Creates MR with updated CPU/RAM/disk → approve → merge → ArgoCD syncs → VM live-resized     |
| **Decommission Virtual Machine** | MR-based approval (humans review) | Creates MR that empties kustomization → approve → merge → ArgoCD prunes all K8s resources   |
| **Create VM (Policy Test)**    | Gatekeeper OPA (automated policy) | Publishes directly to main → ArgoCD syncs immediately → Gatekeeper webhook allows or denies |

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

## Demo Scenario B: Resize VM (Resize Virtual Machine)

Shows live VM resizing through the same MR-based approval workflow.

### Steps

1. **Navigate to a VM** in the RHDH catalog → click **Decommission VM** or **Resize VM** link on the entity page
2. Or go to **Create** → select **Resize Virtual Machine**
3. Fill in the VM name, then set new CPU/RAM/disk values
4. Click **Create** — RHDH creates a MR that updates the VM manifests
5. **Show the MR diff** — old vs new resource values are clearly visible
6. **Approve and merge** as `app-owner` / `security-admin`
7. ArgoCD syncs the updated manifests → KubeVirt live-migrates the VM with new resources (no restart needed if hotplug prerequisites are met)

---

## Demo Scenario C: Decommission VM (Decommission Virtual Machine)

Shows the full VM lifecycle completion — retiring a VM through approval and GitOps pruning.

### Steps

1. **Navigate to a VM** in the RHDH catalog → click the **Decommission VM** link on the entity page
2. Or go to **Create** → select **Decommission Virtual Machine**
3. Fill in the VM name, provide a reason, and confirm the backup checkbox
4. Click **Create** — RHDH creates a MR that:
   - Empties `vm-manifests/kustomization.yaml` (removes all resource references)
   - Updates `catalog-info.yaml` to `lifecycle: decommissioned` with decommission metadata
5. **Show the MR diff** — resources removed from kustomization, lifecycle changed
6. **Approve and merge** as `app-owner` / `security-admin`
7. ArgoCD syncs the empty kustomization → `prune: true` deletes all K8s resources (VM, Service, PVC, Secret, ServiceMonitor, VirtualMachineSnapshot)
8. **RHDH catalog** shows the entity as decommissioned (historical record)
9. **Delete the GitLab repo** to remove the ArgoCD Application:
   - **GUI**: GitLab → project → **Settings** → **General** → **Advanced** → **Delete this project**
   - **CLI**:
     ```bash
     source .env
     curl -ks -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
       "https://gitlab.${BASE_DOMAIN}/api/v4/projects/vm-instances%2F<vm-name>"
     ```
   Deletion is immediate — `seed-gitlab.sh` sets `deletion_adjourned_period` to 0 via rails runner (the API enforces min 1, but rails bypasses this).

### What to highlight

- Complete VM lifecycle: create → resize → decommission — all through Git
- Decommission requires approval — same two-person rule as creation
- Audit trail preserved: Git history shows who decommissioned, when, and why
- RHDH catalog entity remains as historical record with `lifecycle: decommissioned`

---

## Demo Scenario D: Gatekeeper Policy Enforcement (Create VM — Policy Test)

Shows automated policy-as-code — Gatekeeper OPA blocks non-compliant VMs at the Kubernetes API level. No human approval needed; the policies enforce compliance automatically.

### Three Policies in Effect

| Policy            | Rule                                                 | Example violation                                 |
| ----------------- | ---------------------------------------------------- | ------------------------------------------------- |
| Naming convention | Name must match `^[a-z]{2,4}-[a-z]+-[0-9]{2}$`       | `badname`, `my-super-long-vm`, `toolong-name-999` |
| Resource limits   | Max 8 CPU, 16 GiB RAM, 100 GiB disk                  | 32 cores, 64 GiB RAM                              |
| Required labels   | Must have `managed-by`, `environment`, `cost-center` | Unchecking "Include required labels"              |

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

| Where           | How                                                                                     |
| --------------- | --------------------------------------------------------------------------------------- |
| **ArgoCD UI**   | Applications → `vm-<name>` → Sync Status shows OutOfSync, click for error details       |
| **CLI**         | `oc get application vm-<name> -n openshift-gitops -o yaml \| grep -A 20 operationState` |
| **CLI (short)** | `oc get applications -n openshift-gitops` — look for `OutOfSync` status                 |

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
# Delete a VM repo from GitLab (immediately, triggers ArgoCD Application removal)
source .env
curl -ks -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://gitlab.${BASE_DOMAIN}/api/v4/projects/vm-instances%2F<vm-name>"

# Or delete the ArgoCD application directly
oc delete application vm-<name> -n openshift-gitops

# Full teardown
./scripts/teardown.sh
```

---

## Troubleshooting

### GitLab not starting

GitLab needs the `anyuid` SCC. Check the SCC RoleBinding:
```bash
oc get rolebinding gitlab-anyuid-scc -n gitlab
```

GitLab takes 3-5 minutes to start. Check pod logs:
```bash
oc logs -n gitlab -l app=gitlab --tail=50
```

### RHDH login fails

1. Check Keycloak is running: `curl -ks https://keycloak.${BASE_DOMAIN}/realms/virt-portal`
2. Verify OIDC client secret matches: compare `.env` `KEYCLOAK_CLIENT_SECRET` with the realm config
3. Check RHDH logs: `oc logs -n rhdh -l rhdh.redhat.com/app=backstage-rhdh --tail=50`

### ArgoCD not discovering VM repos

1. Verify ApplicationSet exists: `oc get applicationset vm-instances -n openshift-gitops`
2. Check GitLab is accessible internally: `oc exec -n openshift-gitops deploy/openshift-gitops-server -- curl -s http://gitlab.gitlab.svc.cluster.local/api/v4/groups/vm-instances/projects`
3. Check the `gitlab-scm-token` Secret has the correct token

### Gatekeeper not blocking VMs

1. Verify Gatekeeper is running: `oc get pods -n openshift-gatekeeper-system`
2. Check constraints exist: `oc get constraints`
3. Verify namespace labels: `oc get ns vm-dev --show-labels` — must have `app.kubernetes.io/part-of=virt-portal`

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
