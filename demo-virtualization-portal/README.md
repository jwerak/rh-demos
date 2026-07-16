# VM Self-Service Portal — Demo Guide

Self-service VM portal: RHDH 1.10 + GitLab CE + ArgoCD + OpenShift Virtualization + Gatekeeper OPA.

## Prerequisites

### Cluster Requirements

- **OpenShift 4.14+** with cluster-admin access
- **OpenShift Virtualization** operator installed and configured (HyperConverged CR deployed)
- At least one DataSource in `openshift-virtualization-os-images` namespace (e.g. `rhel9`, `rhel8`, `fedora`)
- Sufficient cluster resources: GitLab alone requires 4 CPU / 8 GiB RAM

### Tools

| Tool       | Purpose                                                        |
| ---------- | -------------------------------------------------------------- |
| `oc`       | OpenShift CLI (logged in as cluster-admin)                     |
| `curl`     | GitLab API calls (seed-gitlab.sh)                              |
| `htpasswd` | Demo user creation (create-demo-users.sh) — from `httpd-tools` |
| `git`      | Push templates to GitLab                                       |
| `openssl`  | Generate secrets if not provided                               |
| `python3`  | Parse Keycloak API responses                                   |

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

| Variable                  | Description                                                  | Example                                |
| ------------------------- | ------------------------------------------------------------ | -------------------------------------- |
| `BASE_DOMAIN`             | Custom domain for routes (wildcard DNS must point to router) | `virt-portal.example.com`              |
| `GITLAB_ADMIN_PASSWORD`   | GitLab root password                                         | `MySecurePass123`                      |
| `GITLAB_TOKEN`            | GitLab PAT for RHDH (must start with `glpat-`)               | `glpat-rhdh-portal-token`              |
| `BACKEND_SECRET`          | RHDH backend auth secret                                     | `openssl rand -base64 32`              |
| `DEMO_PASSWORD`           | Password for Keycloak demo users                             | `DemoPass123`                          |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak admin password                                      | `KcAdmin123`                           |
| `KEYCLOAK_CLIENT_SECRET`  | OIDC client secret for RHDH                                  | any random string                      |
| `GITHUB_REPO`             | This repo's Git URL (for ArgoCD)                             | `https://github.com/user/rh-demos.git` |
| `GIT_REVISION`            | Git branch for ArgoCD                                        | `master`                               |

### 2. Deploy

```bash
./scripts/deploy.sh
```

The script runs 7 phases:

| Phase | What it does                                 | Duration |
| ----- | -------------------------------------------- | -------- |
| 0     | Verify `oc login`                            | instant  |
| 1     | Install OpenShift GitOps Operator + RBAC     | ~2 min   |
| 2     | Deploy RHDH Operator via ArgoCD              | ~3 min   |
| 3     | Deploy GitLab CE (on-cluster)                | ~5 min   |
| 3b    | Deploy Keycloak + configure OIDC             | ~2 min   |
| 4     | Deploy RHDH (Backstage CR + config)          | ~3 min   |
| 5     | Seed GitLab (PAT, groups, users, templates)  | ~1 min   |
| 6     | Deploy demo environments + VM ApplicationSet | instant  |
| 7     | Install Gatekeeper OPA + policies            | ~3 min   |

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

## Catalog Items and Enforcement Mechanisms

| Template                         | Enforcement                       | How it works                                                                                |
| -------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------- |
| **Create Virtual Machine**       | MR-based approval (humans review) | Creates GitLab MR → app-owner + security-admin approve → merge → ArgoCD syncs → VM created  |
| **Resize Virtual Machine**       | MR-based approval (humans review) | Creates MR with updated CPU/RAM/disk → approve → merge → ArgoCD syncs → VM live-resized     |
| **Decommission Virtual Machine** | MR-based approval (humans review) | Creates MR that empties kustomization → approve → merge → ArgoCD prunes all K8s resources   |
| **Request Network Exception**    | MR-based approval (humans review) | Creates MR with NetworkPolicy exception → security-admin approves → ArgoCD syncs exception  |
| **Create VM (Policy Test)**      | Gatekeeper OPA (automated policy) | Publishes directly to main → ArgoCD syncs immediately → Gatekeeper webhook allows or denies |

### Network Zone Architecture

Each VM is assigned a **network zone** (frontend, backend, database) that controls which tiers can communicate:

```
AdminNetworkPolicy (cluster level, enforced by OVN-Kubernetes)
  ✅ Allow: frontend → backend
  ✅ Allow: backend → database
  🔒 Pass:  frontend → database  →  delegates to namespace NetworkPolicy
                                          │
                            ┌──────────────┼──────────────┐
                            │              │              │
                       default-deny   exception NP    per-VM NP
                       (blocks all)   (if approved)   (zone ingress)
                            │              │
                         DENIED        ALLOWED
```

- **AdminNetworkPolicy** enforces zone rules at the cluster level (cannot be bypassed by namespace admins)
- **Default-deny-ingress** NetworkPolicy blocks all ingress in vm-dev/staging/prod namespaces
- **Per-VM NetworkPolicy** opens ingress based on the VM's zone (created by the template)
- **Exception NetworkPolicy** overrides the default deny for a specific VM and port (created via "Request Network Exception")

---

## Demo Scenario A: Standard VM Order (Create Virtual Machine)

Shows the human approval workflow — requestor selects service from catalog, enters parameters including network zone, two approvers review the network segment and merge before the VM is provisioned.

### Steps

1. **Login to RHDH** as `vm-requestor`
2. Go to **Create** → select **Create Virtual Machine**
3. Fill in the form:
   - VM Name: `dev-web-01` (must match `prefix-name-number` format)
   - CPU: 2, Memory: 4 GiB, Disk: 30 GiB
   - OS Image: RHEL 9, Environment: Development
   - **Network Zone: Backend** (application tier — accepts traffic from frontend only)
   - Owner: pick `vm-requestor`, Cost Center: CC-001
4. Click **Create** — RHDH creates a GitLab repo and opens a Merge Request
5. **Show the MR in GitLab** — click the "Merge Request" link in the output
   - The MR description shows a summary table including the **Network Zone**
   - Click **Changes** tab to show the diff:
     - `virtualmachine.yaml` — VM with `network-zone: backend` label on both VM and pod template
     - `networkpolicy.yaml` — NetworkPolicy allowing ingress **only from frontend zone**
     - Other manifests (Service, Secret, ServiceMonitor, VirtualMachineSnapshot)
6. **Login to GitLab** as `app-owner` → review the VM configuration and approve
7. **Login to GitLab** as `security-admin` → review the **network zone and NetworkPolicy**, approve and merge
8. **Show ArgoCD UI** — within 30 seconds, ArgoCD discovers the new repo and syncs
   - Click application `vm-dev-web-01` → show the resource tree with VirtualMachine + NetworkPolicy
9. **Show OpenShift Console** → **Networking** → **NetworkPolicies** in namespace `vm-dev`
   - The per-VM zone policy `dev-web-01-zone` is visible with its ingress rules
10. **Show RHDH catalog** → find `dev-web-01` entity
    - Annotations show zone, CPU, RAM, environment
    - Links: Resize VM, Decommission VM, Request Network Exception

### What to highlight

- **Network zone selection** — requestor chooses the security zone, security-admin reviews the NetworkPolicy in the MR diff
- **AdminNetworkPolicy** — cluster-level enforcement of zone traffic rules (show in OpenShift Console → **Networking** → **AdminNetworkPolicies**)
- Git is the single source of truth — all changes go through Git
- Two-person approval — no single person can provision a VM alone
- Full audit trail in Git history — who requested, who approved, when
- VM is registered in RHDH catalog with zone metadata (acts as lightweight CMDB)

---

## Demo Scenario B: Policy Violation and Network Exception

Shows what happens when a VM needs access to a restricted network zone — the AdminNetworkPolicy blocks it, and the user requests an exception through the portal.

### Prerequisites

Create two VMs first (via Scenario A):
- `dev-web-01` in **frontend** zone
- `dev-db-01` in **database** zone

### Steps — Show the Policy

1. **Open OpenShift Console** → **Networking** → **AdminNetworkPolicies**
   - Show `virt-portal-backend-ingress` — allows frontend → backend
   - Show `virt-portal-database-ingress` — allows backend → database, **passes** frontend → database to namespace NetworkPolicy
2. **Open OpenShift Console** → **Networking** → **NetworkPolicies** in `vm-dev`
   - Show `default-deny-ingress` — blocks all ingress by default
   - Show `dev-web-01-zone` — frontend VM, accepts all same-namespace traffic
   - Show `dev-db-01-zone` — database VM, accepts only from backend zone
3. **Explain the enforcement chain**:
   - frontend → database: ANP says **Pass** → delegates to namespace NetworkPolicy → `default-deny-ingress` blocks → no exception exists → **traffic denied**
   - "The frontend VM `dev-web-01` cannot reach the database VM `dev-db-01` — there is no NetworkPolicy that allows it"

### Steps — Request an Exception

4. **Navigate to** `dev-web-01` in the **RHDH catalog** → click **Request Network Exception**
5. Fill in the form:
   - Source VM: `dev-web-01` (pre-filled from catalog link)
   - Target Zone: Database
   - Port: 5432 (PostgreSQL)
   - Environment: Development (pre-filled)
   - Justification: "Frontend app needs direct DB access for health checks"
6. Click **Create** — RHDH creates a GitLab repo and MR with the exception NetworkPolicy
7. **Show the MR in GitLab** — click the "Merge Request" link
   - The MR description shows the **justification** and a summary table
   - Click **Changes** tab — the diff shows `networkpolicy-exception.yaml`:
     - Selects destination pods with `network-zone: database`
     - Allows ingress from pods with `kubevirt.io/domain: dev-web-01` on port 5432 only
   - "Security-admin can see exactly which VM, which zone, and which port — nothing more"

### Steps — Security Review

8. **Login to GitLab** as `security-admin`
   - Review the justification in the MR description
   - Review the NetworkPolicy diff — verify the scope is minimal (one VM, one port)
   - **Approve and merge** the MR (or close it to deny)

### Steps — Show the Result

9. **Show ArgoCD UI** — a new application `vm-dev-web-01-netexc-database` appears and syncs ✅
10. **Show OpenShift Console** → **Networking** → **NetworkPolicies** in `vm-dev`
    - A new policy `dev-web-01-to-database-exception` now exists
    - Click it to show: allows `dev-web-01` → database zone on port 5432
    - "This exception NetworkPolicy overrides the default-deny — the frontend VM can now reach the database zone on this specific port"
11. **Show RHDH catalog** — a new entity `dev-web-01-netexc-database` of type `network-exception` is registered with all exception metadata

### Steps — Revoke the Exception

12. **Go to GitLab** → `vm-instances/dev-web-01-netexc-database` → **Settings** → **General** → **Advanced** → **Delete this project**
13. **Show ArgoCD UI** — the application disappears within 30 seconds
14. **Show OpenShift Console** → **NetworkPolicies** — the exception policy is gone
    - "Traffic is blocked again — revoking an exception is as simple as deleting the repo"

### What to highlight

- **AdminNetworkPolicy** is OCP-native (OVN-Kubernetes) — cluster-admin controls which flows are always allowed, always denied, or exception-eligible
- **Pass + default-deny** = blocked by default, but exceptions are possible via namespace NetworkPolicy
- Exception goes through the **same MR-based approval** workflow — security-admin reviews the exact NetworkPolicy
- Full audit trail: who requested the exception, why, who approved, when it was revoked
- Revoking = deleting the repo → ArgoCD prunes → immediate effect

---

## Demo Scenario C: Change Existing Service (Resize Virtual Machine)

Shows live VM resizing through the same MR-based approval workflow. Network zone is preserved.

### Steps

1. **Navigate to a VM** in the **RHDH catalog** → click **Resize VM** link on the entity page
   - Or go to **Create** → select **Resize Virtual Machine**
2. The form opens with pre-filled values (VM name, environment, network zone — all read-only)
3. Change the resource values: e.g. CPU: 4, Memory: 8 GiB
4. Click **Create** — RHDH creates a MR that updates the VM manifests
5. **Show the MR in GitLab** — click the "Merge Request" link
   - Click **Changes** tab — the diff shows updated CPU/RAM values in `virtualmachine.yaml`
   - Note: `network-zone` label is preserved (unchanged)
6. **Approve and merge** as `app-owner` / `security-admin`
7. **Show ArgoCD UI** — the existing application re-syncs with updated manifests
8. **Show OpenShift Console** → **Virtualization** → **VirtualMachines** → `dev-web-01`
   - VM shows updated CPU/RAM values (live-resize if hotplug prerequisites are met)
9. **Show RHDH catalog** — the entity annotations are updated with new CPU/RAM values

---

## Demo Scenario D: Decommission Service (Decommission Virtual Machine)

Shows the full VM lifecycle completion — retiring a VM through approval and GitOps pruning.

### Steps

1. **Navigate to a VM** in the **RHDH catalog** → click the **Decommission VM** link on the entity page
   - Or go to **Create** → select **Decommission Virtual Machine**
2. Fill in the VM name, provide a reason, and confirm the backup checkbox
3. Click **Create** — RHDH creates a MR
4. **Show the MR in GitLab** — click the "Merge Request" link
   - Click **Changes** tab — the diff shows:
     - `kustomization.yaml` → `resources: []` (all resource references removed)
     - `catalog-info.yaml` → `lifecycle: decommissioned` with decommission metadata
   - "When ArgoCD syncs the empty kustomization, `prune: true` deletes all Kubernetes resources"
5. **Approve and merge** as `app-owner` / `security-admin`
6. **Show ArgoCD UI** — the application syncs, all resources are pruned (VM, Service, PVC, Secret, ServiceMonitor, VirtualMachineSnapshot, NetworkPolicy)
7. **Show OpenShift Console** → **Virtualization** → **VirtualMachines** in `vm-dev` — the VM is gone
8. **Show RHDH catalog** — the entity remains with `lifecycle: decommissioned` (historical record)
9. **Delete the GitLab repo** to remove the ArgoCD Application:
   - GitLab → project → **Settings** → **General** → **Advanced** → **Delete this project**
   - Deletion is immediate

### What to highlight

- Complete VM lifecycle: create → resize → decommission — all through Git
- Decommission requires approval — same two-person rule as creation
- ArgoCD prune removes all resources including NetworkPolicies and network exceptions
- Audit trail preserved: Git history shows who decommissioned, when, and why
- RHDH catalog entity remains as historical record with `lifecycle: decommissioned`

---

## Supplementary Demo: Gatekeeper Policy Enforcement (Create VM — Policy Test)

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
                             │ oc apply (VirtualMachine CR + NetworkPolicy)
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
                     │
                     ▼
              ┌──────────────────────────────────────────┐
              │     OVN-Kubernetes Network Enforcement    │
              │                                          │
              │  AdminNetworkPolicy (cluster-level):     │
              │  ✅ frontend → backend    (Allow)         │
              │  ✅ backend  → database   (Allow)         │
              │  🔒 frontend → database   (Pass→NP→deny) │
              │                                          │
              │  Per-VM NetworkPolicy (namespace-level):  │
              │  ✓ Zone-based ingress rules              │
              │  ✓ Exception NPs for approved overrides  │
              └──────────────────────────────────────────┘
```
