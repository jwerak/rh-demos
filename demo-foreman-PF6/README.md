# Foreman PF6 Demo on OpenShift Virtualization

Deploy [Foreman](https://theforeman.org/) (with PatternFly 6 UI) as a lifecycle management server on OpenShift Virtualization. A single RHEL 9 VM runs all Foreman services via podman-compose, with client VMs that auto-register for host management.

## Architecture

```
                    ┌─────────────────────┐
                    │  OpenShift Router    │
                    │  (edge TLS)          │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │  Service :3000      │
                    └──────────┬──────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│  Foreman VM  (4 vCPU, 8Gi RAM, 50Gi disk)                  │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  podman-compose                                        │ │
│  │  ┌─────────┐  ┌──────────┐  ┌───────────────────────┐ │ │
│  │  │  Rails   │  │ Postgres │  │  Redis (cache+tasks)  │ │ │
│  │  │  :3000   │  │  :5432   │  │  :6379                │ │ │
│  │  └─────────┘  └──────────┘  └───────────────────────┘ │ │
│  │  ┌──────────────────┐  ┌───────────────────────────┐  │ │
│  │  │  Orchestrator    │  │  Worker (Sidekiq -c 15)   │  │ │
│  │  │  (Sidekiq -c 1)  │  │  default + remote_exec    │  │ │
│  │  └──────────────────┘  └───────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                               ▲
                               │  Registration
              ┌────────────────┼────────────────┐
              │                │                │
     ┌────────▼──────┐ ┌──────▼───────┐ ┌──────▼───────┐
     │  Client VM    │ │  Pool VM 1   │ │  Pool VM 2   │
     │  1CPU / 2Gi   │ │  1CPU / 2Gi  │ │  1CPU / 2Gi  │
     └───────────────┘ └──────────────┘ └──────────────┘
```

## Prerequisites

- OpenShift 4.14+ with OpenShift Virtualization operator
- RHEL 9 DataSource in `openshift-virtualization-os-images` namespace
- RHSM org ID and activation key
- DNS CNAME record pointing `FOREMAN_FQDN` to the OpenShift router
- `oc`, `podman`, `virtctl`, `sshpass` CLI tools
- Pre-built Foreman container image (see below)

## Quick Start

### 1. Build and push the Foreman image

```bash
# From the demo directory
./scripts/build-push-image.sh --push
```

This builds the image from `~/git/foreman/` and pushes to `quay.io/jwerak/foreman:latest`.

### 2. Configure environment

```bash
cp .env.sample .env
# Edit .env: set RHSM_ORG, RHSM_ACTIVATION_KEY, FOREMAN_FQDN
vi .env
source .env
```

### 3. Create DNS CNAME

```bash
# Find your cluster's apps domain
oc get ingress.config cluster -o jsonpath='{.spec.domain}'
# Create CNAME: foreman.example.com → *.apps.<cluster-domain>
```

### 4. Deploy

```bash
source .env
./scripts/create-rhsm-secret.sh
./scripts/deploy.sh
```

### 5. Monitor installation (~10-15 min)

```bash
sshpass -p "$DEMO_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ProxyCommand="virtctl port-forward --stdio vmi/foreman.foreman-demo 22" \
  cloud-user@localhost 'sudo tail -f /var/log/foreman-setup.log'
```

### 6. Access Web UI

```
URL:      https://<FOREMAN_FQDN>
Username: admin
Password: <DEMO_PASSWORD from .env>
```

## Demo Scenarios

```bash
./scripts/demo-scenarios.sh <number>
```

| # | Scenario | Description |
|---|---|---|
| 1 | Zero-Touch Provisioning | Deploy a client VM, watch auto-registration |
| 2 | Elastic Scaling | Scale client pool from 0 to N replicas |
| 3 | Self-Healing | Delete VMI, watch auto-recovery |
| 4 | Host Management | Query registered hosts and facts via API |
| 5 | Container Lifecycle | podman-compose ops: status, logs, restart |

## Adding External VMs

Client VMs auto-register to Foreman using the Global Registration endpoint. The cloud-init:

1. Resolves the Foreman service via Kubernetes DNS
2. Waits for the Foreman API to be available
3. Calls `https://<FOREMAN_FQDN>/register` to execute the registration script

Scale the client pool:

```bash
oc scale vmpool client-pool -n foreman-demo --replicas=3
```

Or deploy a single client:

```bash
oc apply -f k8s/base/client-vm.yaml  # (after template substitution via deploy.sh)
```

## Resource Requirements

| Component | vCPU | RAM | Storage |
|---|---|---|---|
| Foreman VM | 4 | 8 Gi | 50 Gi |
| Client (each) | 1 | 2 Gi | 30 Gi |
| **Total (Foreman + 2 clients)** | **6** | **12 Gi** | **110 Gi** |

## Verification

```bash
./scripts/verify.sh
```

## Troubleshooting

### Foreman VM not starting
```bash
oc get vm,vmi,dv -n foreman-demo
oc describe vm foreman -n foreman-demo
```

### Cloud-init issues
```bash
# SSH into the VM and check the setup log
sshpass -p "$DEMO_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ProxyCommand="virtctl port-forward --stdio vmi/foreman.foreman-demo 22" \
  cloud-user@localhost 'sudo cat /var/log/foreman-setup.log'
```

### Container issues inside the VM
```bash
# Check podman-compose status
virtctl ssh cloud-user@foreman -n foreman-demo
sudo podman-compose -f /opt/foreman/docker-compose.yml ps
sudo podman-compose -f /opt/foreman/docker-compose.yml logs app
```

### API not responding
```bash
curl -sk https://$FOREMAN_FQDN/api/v2/status
```

## Cleanup

```bash
oc delete namespace foreman-demo
```
