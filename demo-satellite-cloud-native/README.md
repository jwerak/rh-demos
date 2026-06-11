# Cloud-Native RHEL Infrastructure on OpenShift Virtualization

Red Hat Satellite + IdM (FreeIPA) + RHEL clients running entirely as KubeVirt VMs on the OpenShift pod network. Zero Layer 2 networking, zero PXE — everything is cloud-init driven.

## Architecture

```
                  [ Kubernetes ClusterIP Services ]
             (satellite-svc)               (idm-svc)
                    |                          |
                    v                          v
          +-------------------+      +-------------------+
          |   Satellite VM    |      |      IdM VM       |
          |   4 vCPU, 22 Gi   |      |   2 vCPU, 4 Gi   |
          |   RHEL 9 + Sat 6  |      |   RHEL 9 + IPA   |
          +-------------------+      +-------------------+
                    ^                          ^
                    |  (Repo Sync & Content)   | (Kerberos/LDAP)
                    +-------------+------------+
                                  |
                   +--------------+--------------+
                   |  Default Pod Network (SDN)  |
                   |     Masquerade / OVN-K      |
                   +--------------+--------------+
                                  |
                                  v
                     +--------------------------+
                     |   RHEL Client VM Pool    |
                     |  1 vCPU, 2 Gi each       |
                     |  Auto-registered to both  |
                     +--------------------------+
```

## Prerequisites

- OpenShift 4.14+ with OpenShift Virtualization operator installed
- RHEL 9 cloud image available via DataImportCron (`rhel9` DataSource)
- Storage class supporting RWO PVCs (Ceph RBD, ODF, etc.)
- RHSM credentials (org ID + activation key) for all VMs
- DNS domain where you can create CNAME records (for Web UI access)
- `oc` CLI authenticated to the cluster
- `sshpass` installed locally (for SSH access to VMs via `virtctl port-forward`)

## Setup

### 1. Create DNS CNAME Records

The IdM and Satellite Web UIs are exposed via OpenShift Routes. For the UIs to work without redirect issues, the server FQDNs must match the Route hostnames. Create two CNAME records in your DNS domain pointing to the OpenShift router wildcard:

```
# Find your cluster's apps domain
oc get ingress.config cluster -o jsonpath='{.spec.domain}'
# Example output: apps.cluster-abc.dyn.redhatworkshops.io

# Create these CNAME records in your DNS:
idm.yourdomain.com        CNAME  idm.apps.cluster-abc.dyn.redhatworkshops.io
satellite.yourdomain.com  CNAME  satellite.apps.cluster-abc.dyn.redhatworkshops.io
```

The IdM server will be installed with `idm.yourdomain.com` as its FQDN, and the IPA Kerberos realm will be derived from your domain (e.g., `YOURDOMAIN.COM`). Client VMs get hostnames like `client-<id>.yourdomain.com` and are enrolled into this realm.

### 2. Configure Environment

```bash
cp .env.sample .env
```

Edit `.env` with your values:

```bash
# RHSM credentials (get from https://console.redhat.com/settings/connector/activation-keys)
export RHSM_ORG=12345678
export RHSM_ACTIVATION_KEY=your-activation-key

# DNS names matching the CNAMEs you created above
export IDM_FQDN=idm.yourdomain.com
export SAT_FQDN=satellite.yourdomain.com
```

### 3. Create the RHSM Credentials Secret

```bash
source .env
./scripts/create-rhsm-secret.sh
```

## Quick Start

```bash
source .env
./scripts/deploy.sh

# Monitor IdM install (~10 min)
# Monitor Satellite install (~20-30 min)
# The deploy script prints monitoring commands and Web UI URLs at the end

# Once infra is ready, scale client pool
oc scale vmpool client-pool -n satellite-cloud-native --replicas=2
```

The deploy script validates DNS resolution, checks for the RHSM secret, and substitutes your FQDNs into all manifests before applying them.

## Web UI Access

Both Satellite and IdM expose their web UIs via OpenShift Routes (TLS passthrough) using the DNS names you configured in `.env`. Your browser will show a certificate warning (self-signed certs) — accept it to proceed.

### URLs

- **Satellite:** `https://<SAT_FQDN>` (e.g., `https://satellite.veverak.net`)
- **IdM:** `https://<IDM_FQDN>` (e.g., `https://idm.veverak.net`)

### Satellite Web UI

- **Login:** `admin` / `<DEMO_PASSWORD>`
- Shows: registered hosts, content views, lifecycle environments, activation keys
- Navigate to **Hosts > All Hosts** to see enrolled RHEL clients
- Navigate to **Content > Lifecycle > Activation Keys** to see `rhel9-key`

### IdM (FreeIPA) Web UI

- **Login:** `admin` / `<DEMO_PASSWORD>`
- Shows: enrolled hosts, users, host groups, Kerberos policies
- Navigate to **Identity > Hosts** to see all auto-enrolled client VMs
- Navigate to **Identity > Users** to see the `demouser` account
- Navigate to **Identity > Host Groups** to see `satellite-clients`

### SSH Access to VMs

For direct shell access to any VM (useful during demos):

```bash
# SSH via virtctl port-forward (requires sshpass)
sshpass -p "$DEMO_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ProxyCommand="virtctl port-forward --stdio vmi/<vm-name>.satellite-cloud-native 22" \
  cloud-user@localhost

# Examples:
# IdM server
sshpass -p "$DEMO_PASSWORD" ssh ... vmi/idm.satellite-cloud-native ...
# Satellite server
sshpass -p "$DEMO_PASSWORD" ssh ... vmi/satellite.satellite-cloud-native ...
# Client VM
sshpass -p "$DEMO_PASSWORD" ssh ... vmi/client.satellite-cloud-native ...

# Or use virtctl console for serial console access (no sshpass needed)
virtctl console vmi/idm -n satellite-cloud-native
# Login: cloud-user / see DEMO_PASSWORD in .env
```

## Demo Scenarios

### Demo 1: Zero-Touch Provisioning

Deploy a RHEL client that automatically registers to Satellite and enrolls in IdM — no manual configuration.

```bash
./scripts/demo-scenarios.sh 1

# Verify (after ~5 min):
oc exec -n satellite-cloud-native vmi/client -- subscription-manager identity
oc exec -n satellite-cloud-native vmi/idm -- bash -c "echo '$DEMO_PASSWORD' | kinit admin && ipa host-find"
```

### Demo 2: Elastic Scaling

Scale a pool of RHEL clients from 0 to 5 with a single command. Each VM auto-registers independently.

```bash
./scripts/demo-scenarios.sh 2

# Or manually:
oc scale vmpool client-pool -n satellite-cloud-native --replicas=5

# Verify all registered:
oc exec -n satellite-cloud-native vmi/satellite -- hammer host list --organization 'Demo_Org'
```

### Demo 3: Self-Healing

Delete a running VMI and watch OpenShift automatically recreate it, demonstrating platform resilience.

```bash
./scripts/demo-scenarios.sh 3

# Or manually:
oc delete vmi/client -n satellite-cloud-native
# Watch it come back:
oc get vmi -n satellite-cloud-native -w
```

### Demo 4: IP-Agnostic Kerberos

Prove that multiple VMs with identical internal NAT IPs (`10.0.2.x`) can each hold valid, independent Kerberos tickets.

```bash
./scripts/demo-scenarios.sh 4
```

The `noaddresses = true` setting in `/etc/krb5.conf` prevents Kerberos from binding tickets to the internal masquerade IP.

### Demo 5: Network Micro-Segmentation

Demonstrate that VMs inherit Kubernetes NetworkPolicy — client VMs can reach Satellite and IdM but cannot communicate with each other.

```bash
./scripts/demo-scenarios.sh 5
```

The `NetworkPolicy` allows `role: client` → `role: infra` traffic and blocks `role: client` → `role: client`.

## Resource Requirements

| VM | vCPUs | RAM | Storage |
|----|-------|-----|---------|
| IdM | 2 | 4 Gi | 30 Gi |
| Satellite | 4 | 22 Gi | 100 Gi root + 150 Gi data |
| Client (each) | 1 | 2 Gi | 30 Gi |

**Total (infra + 2 clients):** 8 vCPUs, 30 Gi RAM, 340 Gi storage

## Kustomize Structure

```
k8s/
├── base/
│   ├── kustomization.yaml              # Resource list + common labels
│   ├── namespace.yaml                   # satellite-cloud-native
│   ├── idm-vm.yaml                      # IdM VirtualMachine
│   ├── idm-cloudinit-secret.yaml        # IdM cloud-init (ipa-server-install)
│   ├── idm-service.yaml                 # Kerberos, LDAP, HTTP/S ports
│   ├── idm-route.yaml                   # TLS passthrough for FreeIPA Web UI
│   ├── satellite-vm.yaml                # Satellite VirtualMachine
│   ├── satellite-cloudinit-secret.yaml  # Satellite cloud-init (satellite-installer)
│   ├── satellite-service.yaml           # HTTP/S, qdrouterd ports
│   ├── satellite-route.yaml             # TLS passthrough for Web UI
│   ├── satellite-data-pvc.yaml          # 150 Gi for /var/lib/pulp
│   ├── client-vm.yaml                   # Single RHEL client
│   ├── client-cloudinit-secret.yaml     # Client cloud-init (register + enroll)
│   ├── client-pool.yaml                 # VirtualMachinePool (starts at 0)
│   └── network-policy.yaml              # Client isolation
└── overlays/
    └── demo/
        └── kustomization.yaml           # Adds environment: demo label
```

## Networking

All VMs use **masquerade mode** on the default pod network (OVN-Kubernetes):

- VMs get internal NAT addresses (`10.0.2.x` inside the guest)
- Inter-VM communication happens via Kubernetes ClusterIP Services
- External access to Satellite and IdM UIs via OpenShift Routes (TLS passthrough)
- No bridge networking, multus, or static IPs required

## Troubleshooting

### VM not starting
```bash
oc describe vm/<name> -n satellite-cloud-native
oc get events -n satellite-cloud-native --sort-by='.lastTimestamp'
```

### Cloud-init not running
```bash
oc console vmi/<name> -n satellite-cloud-native
# Login: cloud-user / see DEMO_PASSWORD in .env
# Check: cat /var/log/cloud-init-output.log
```

### Satellite installer failing
```bash
oc exec -n satellite-cloud-native vmi/satellite -- cat /var/log/satellite-setup.log
oc exec -n satellite-cloud-native vmi/satellite -- cat /var/log/foreman-installer/satellite.log
```

### IdM installer failing
```bash
oc exec -n satellite-cloud-native vmi/satellite -- cat /var/log/idm-setup.log
oc exec -n satellite-cloud-native vmi/idm -- cat /var/log/ipaserver-install.log
```

### Client not registering
```bash
oc exec -n satellite-cloud-native vmi/client -- cat /var/log/client-setup.log
oc exec -n satellite-cloud-native vmi/client -- subscription-manager status
oc exec -n satellite-cloud-native vmi/client -- ipa-client-install --uninstall  # retry
```

### DataVolume stuck importing
```bash
oc get dv -n satellite-cloud-native
oc describe dv/<name> -n satellite-cloud-native
```

## Clean Up

```bash
# Remove everything
oc delete -k k8s/overlays/demo/

# Or remove just clients
oc scale vmpool client-pool -n satellite-cloud-native --replicas=0
oc delete vm/client -n satellite-cloud-native
```

## Default Credentials

| Service | Username | Password |
|---------|----------|----------|
| Satellite Web UI | admin | `<DEMO_PASSWORD>` |
| IdM admin | admin | `<DEMO_PASSWORD>` |
| IdM Directory Manager | - | `<DEMO_PASSWORD>` |
| Demo user (IdM) | demouser | `<DEMO_PASSWORD>` |
| VM SSH (all VMs) | cloud-user | `<DEMO_PASSWORD>` |

> All services use the same password. Run `source .env` to load it, or check `.env` for the value.
>
> **Warning:** These are demo-only credentials. Do not use in production.

## References

- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
- [Red Hat Satellite Installation Guide](https://docs.redhat.com/en/documentation/red_hat_satellite)
- [Red Hat IdM Installation Guide](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/installing_identity_management)
- [KubeVirt VirtualMachinePool](https://kubevirt.io/user-guide/virtual_machines/pool/)
- [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
