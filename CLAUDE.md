# CLAUDE.md

Collection of Red Hat technology demos. Each demo is self-contained in its own `demo-*/` directory with its own `CLAUDE.md` for context. Read the relevant demo's CLAUDE.md when working in that directory.

## Demo Index

| Directory | Description |
|---|---|
| `demo-acm-policies/` | ACM OperatorPolicy: operator install, upgrade, removal across clusters |
| `demo-acm-gitops/` | ACM GitOps: ArgoCD-managed operator policies with dev-to-prod promotion |
| `demo-aiops/` | AIOps: AAP workflow setup + AI ops assistant agent on OpenShift |
| `demo-containerfile/` | Manifest-driven tar archive file copying into container images |
| `demo-hybrid-app/` | Hybrid cloud: KubeVirt VM (PostgreSQL) + containers (Frontend, Backend, Redis) |
| `demo-network-manager/` | RHEL 10 NetworkManager IP alias management via Ansible |
| `demo-podman-build-push-run/` | Basic podman build/push/run workflow |
| `demo-satellite/` | Red Hat Satellite + AAP integration (older, less maintained) |
| `demo-satellite-cloud-native/` | Cloud-native Satellite + IdM + RHEL clients on OpenShift Virtualization |
| `demo-system-roles/` | RHEL System Roles: host registration, Cockpit, monitoring |
| `demo-windows-vm/` | Windows Server golden image via Tekton pipeline on OpenShift Virtualization |

## Unified Deployment Controller

`ansible-controller/` provides centralized deployment for demos via `ansible-navigator`:

```bash
# Demos without VM provisioning
cd ansible-controller
ansible-navigator run --extra-vars "demo_name=<demo-name>"

# Demos requiring VMs (e.g., network-manager)
ansible-navigator run -i inventory/demo-network-manager.yml --extra-vars "demo_name=demo-network-manager provisioner=libvirt"
```

Available demo names: `aiops`, `demo-acm-policies`, `demo-containerfile`, `demo-hybrid-app`, `demo-network-manager`, `demo-podman-build-push-run`, `demo-satellite`, `demo-system-roles`

## Conventions

- Each demo has its own README.md (human docs) and CLAUDE.md (agent context)
- Credentials go in `.env` (copied from `.env.sample`, gitignored)
- Most OpenShift demos use kustomize base/overlay patterns
- Ansible demos use `ansible-navigator` with containerized execution environments
