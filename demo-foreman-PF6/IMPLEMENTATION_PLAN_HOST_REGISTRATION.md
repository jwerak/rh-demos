# Implementation Plan: Host Registration + Demo Configuration for demo-foreman-PF6

## Part 1: Fix Host Registration

### Problem

Client VMs cannot register to Foreman because:
1. Foreman's Global Registration endpoint (`/register`) requires a JWT Bearer token
2. The current client cloud-init tries to `curl` the endpoint without auth — gets rejected
3. No mechanism exists to pass the registration command from Foreman VM to client VMs

### Solution

Mirror the satellite-cloud-native pattern: Foreman VM generates a registration script post-setup and serves it via a static file. Client VMs fetch and execute that script.

### Architecture

```
Foreman VM (cloud-init Phase 6 — NEW)
  │
  ├─ POST /api/v2/registration_commands → gets curl|bash one-liner with JWT
  ├─ Saves one-liner to /opt/foreman/registration/register.sh
  └─ Serves it via a simple HTTP endpoint (python3 -m http.server on port 8080)
       │
       ▼
  Service foreman:8080 (add to foreman-service.yaml)
       │
Client VMs (cloud-init)
  │
  ├─ Resolves foreman.foreman-demo.svc.cluster.local
  ├─ Waits for http://foreman-svc:8080/register.sh to be available
  └─ Downloads and executes register.sh
```

### Files to Modify

#### 1. `k8s/base/foreman-cloudinit-secret.yaml`

Add **Phase 6** after Phase 5 (systemd service), before the "Setup Complete" message:

```bash
echo "=== Phase 6: Generate Registration Command ==="
mkdir -p /opt/foreman/registration

# Generate registration command via Foreman API (insecure=true skips CA verification)
REG_CMD=$(curl -sf -u admin:__DEMO_PASSWORD__ \
  http://127.0.0.1:3000/api/v2/registration_commands \
  -X POST -H "Content-Type: application/json" \
  -d '{"registration_command": {"insecure": true}}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['registration_command'])")

echo "#!/bin/bash" > /opt/foreman/registration/register.sh
echo "${REG_CMD}" >> /opt/foreman/registration/register.sh
chmod 644 /opt/foreman/registration/register.sh
echo "Registration script saved."

# Serve the registration directory on port 8080 via systemd
printf '%s\n' \
  '[Unit]' \
  'Description=Foreman registration file server' \
  'After=network-online.target' \
  '' \
  '[Service]' \
  'Type=simple' \
  'WorkingDirectory=/opt/foreman/registration' \
  'ExecStart=/usr/bin/python3 -m http.server 8080' \
  'Restart=always' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' \
  > /etc/systemd/system/foreman-registration.service
systemctl daemon-reload
systemctl enable --now foreman-registration.service
echo "Registration file server running on port 8080."
```

#### 2. `k8s/base/foreman-service.yaml`

Add port 8080 to the existing Service:

```yaml
    - name: registration
      port: 8080
      targetPort: 8080
      protocol: TCP
```

#### 3. `k8s/base/client-cloudinit-secret.yaml`

Replace the entire `runcmd` registration section. The new client cloud-init should:

```bash
echo "=== Registering with Foreman ==="
# Fetch registration script from Foreman's file server (port 8080 via k8s Service)
FOREMAN_SVC_IP=$(getent hosts foreman.foreman-demo.svc.cluster.local | awk '{print $1}')
REG_URL="http://${FOREMAN_SVC_IP}:8080/register.sh"

for i in $(seq 1 60); do
  if curl -sf "${REG_URL}" -o /tmp/register.sh 2>/dev/null; then
    echo "Got registration script, executing..."
    bash /tmp/register.sh
    break
  fi
  echo "Waiting for registration script... attempt ${i}/60"
  sleep 20
done
```

Remove the existing `REGISTRATION_URL` logic that tries `/register?fqdn=...` without auth.
Remove the `curl -sk https://FOREMAN_FQDN/api/v2/status` wait loop — waiting for port 8080 implicitly means Foreman is ready.

---

## Part 2: Seed Demo Configuration

### Goal

After Foreman boots and seeds, populate it with realistic demo data that showcases Foreman's multi-tenant, multi-location lifecycle management capabilities.

### What to Create

All created via the Foreman API (`curl -sf -u admin:__DEMO_PASSWORD__ http://127.0.0.1:3000/api/v2/...`) in a new **Phase 7** of the cloud-init.

#### Organizations (3)

| Name | Description |
|---|---|
| `ACME Corp` | Primary customer — production workloads |
| `Globex Industries` | Secondary customer — development/staging |
| `Default Organization` | Already exists (id=1) — keep as fallback |

#### Locations (4)

| Name | Description |
|---|---|
| `US-East / Virginia` | Primary datacenter |
| `US-West / Oregon` | DR site |
| `EU-Central / Frankfurt` | GDPR-compliant region |
| `Default Location` | Already exists (id=1) |

#### Domains (2)

| Name |
|---|
| `acme.example.com` |
| `globex.example.com` |

#### Operating Systems (2)

| Name | Major | Minor | Family |
|---|---|---|---|
| `RHEL` | 9 | 4 | Redhat |
| `CentOS_Stream` | 9 | 0 | Redhat |

Associate with `x86_64` architecture (id=1) and `Kickstart default` partition table.

#### Host Groups (5 — nested hierarchy)

```
ACME Corp/
  ├── acme-production        (org: ACME Corp, loc: US-East, os: RHEL 9, domain: acme.example.com)
  │   ├── acme-prod-web      (parent: acme-production, compute_profile: 2-Medium)
  │   └── acme-prod-db       (parent: acme-production, compute_profile: 3-Large)
  └── acme-staging           (org: ACME Corp, loc: US-West, os: RHEL 9)

Globex Industries/
  └── globex-development     (org: Globex Industries, loc: EU-Central, os: CentOS Stream 9, domain: globex.example.com)
```

#### Users (3 — besides admin)

| Login | First | Last | Org | Role | Password |
|---|---|---|---|---|---|
| `alice` | Alice | Johnson | ACME Corp | Manager | `__DEMO_PASSWORD__` |
| `bob` | Bob | Smith | Globex Industries | Viewer | `__DEMO_PASSWORD__` |
| `carol` | Carol | Williams | all orgs | Admin (existing role) | `__DEMO_PASSWORD__` |

#### Roles (use built-in roles)

- `Manager` (built-in) — assign to alice
- `Viewer` (built-in) — assign to bob
- `Admin` is a flag, not a role — set `admin: true` for carol

#### Subnets (2)

| Name | Network | Mask | Org | Location |
|---|---|---|---|---|
| `prod-us-east` | 10.10.0.0 | 255.255.0.0 | ACME Corp | US-East / Virginia |
| `dev-eu-central` | 10.20.0.0 | 255.255.0.0 | Globex Industries | EU-Central / Frankfurt |

### Implementation

Add **Phase 7: Seed Demo Configuration** to `k8s/base/foreman-cloudinit-secret.yaml` after Phase 6.

Use a helper function for API calls:

```bash
foreman_api() {
  local method="$1" endpoint="$2"
  shift 2
  curl -sf -u admin:__DEMO_PASSWORD__ \
    -H "Content-Type: application/json" \
    -X "${method}" \
    "http://127.0.0.1:3000/api/v2/${endpoint}" \
    "$@"
}
```

Create resources in dependency order:
1. Organizations (need IDs for everything else)
2. Locations (need IDs for host groups, subnets)
3. Domains
4. Operating Systems + architecture/ptable associations
5. Subnets (need org + location IDs)
6. Host Groups (need org + location + OS + domain + subnet IDs)
7. Users + role assignments (need org IDs)

Capture IDs from creation responses:

```bash
ACME_ORG_ID=$(foreman_api POST organizations \
  -d '{"organization": {"name": "ACME Corp"}}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
```

### Idempotency

Each creation call should tolerate "already exists" (HTTP 422) gracefully — use `|| true` or check first with GET. This allows re-running the setup without errors.

---

## Files to Modify (Summary)

| File | Changes |
|---|---|
| `k8s/base/foreman-cloudinit-secret.yaml` | Add Phase 6 (registration command + file server) and Phase 7 (demo config seed) |
| `k8s/base/foreman-service.yaml` | Add port 8080 for registration file server |
| `k8s/base/client-cloudinit-secret.yaml` | Rewrite registration to fetch from port 8080 |
| `scripts/demo-scenarios.sh` | Update demo4 (Host Management) to show orgs, locations, host groups, users |

## Verification Steps

1. Redeploy Foreman VM (delete VM + DV, recreate via `deploy.sh` or manual apply)
2. Wait for setup to complete (~10-15 min) — check `tail -f /var/log/foreman-setup.log`
3. Verify demo config via API:
   - `curl -sk -u admin:$DEMO_PASSWORD https://$FOREMAN_FQDN/api/v2/organizations` → 3 orgs
   - `curl -sk -u admin:$DEMO_PASSWORD https://$FOREMAN_FQDN/api/v2/locations` → 4 locations
   - `curl -sk -u admin:$DEMO_PASSWORD https://$FOREMAN_FQDN/api/v2/hostgroups` → 5 host groups
   - `curl -sk -u admin:$DEMO_PASSWORD https://$FOREMAN_FQDN/api/v2/users` → 4 users
4. Verify registration endpoint: `curl http://<foreman-svc-ip>:8080/register.sh` returns a script
5. Deploy a client VM and verify it registers
6. Scale pool to 2, verify both register
7. Log in as alice/bob in the Web UI — verify org scoping works
8. Run `scripts/verify.sh` — all checks pass

## Notes

- JWT token in registration command expires after 4 hours. Fine for demos.
- The python3 HTTP server on port 8080 is minimal but sufficient for serving the registration script.
- All demo passwords are `$DEMO_PASSWORD` for simplicity.
- Host groups are nested — Foreman shows them as a tree in the UI, which demonstrates the hierarchy feature.
- Subnets are logical (not routable from the VM) — they exist to show Foreman's IPAM features in the UI.
