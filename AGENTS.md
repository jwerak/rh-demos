# RH Demos

Canonical agent context for this directory. Cursor and Antigravity read `AGENTS.md`. `CLAUDE.md` is a symlink to this file for Claude Code.

Collection of Red Hat technology demos. Each demo is self-contained in its own `demo-*/` directory with its own `AGENTS.md` for context. Read the relevant demo's `AGENTS.md` when working in that directory.

## Demo Index

| Directory | Description |
|---|---|
| `demo-acm-policies/` | ACM OperatorPolicy: operator install, upgrade, removal across clusters |
| `demo-acm-gitops/` | ACM GitOps: ArgoCD-managed operator policies with dev-to-prod promotion |
| `demo-aiops/` | AIOps: AAP workflows, Automation Orchestrator runbook, AI ops assistant on OpenShift |
| `demo-containerfile/` | Manifest-driven tar archive file copying into container images |
| `demo-bootc-fedora-desktop/` | bootc Fedora desktop: kickstart ISO, libvirt qcow2, fullscreen video loop |
| `demo-fedora-silverblue/` | Fedora Silverblue 44 libvirt install and Déjà Dup restic fusermount repro |
| `demo-hybrid-app/` | Hybrid cloud: KubeVirt VM (PostgreSQL) + containers (Frontend, Backend, Redis) |
| `demo-network-manager/` | RHEL 10 NetworkManager IP alias management via Ansible |
| `demo-podman-build-push-run/` | Basic podman build/push/run workflow |
| `demo-satellite/` | Red Hat Satellite + AAP integration (older, less maintained) |
| `demo-satellite-cloud-native/` | Cloud-native Satellite + IdM + RHEL clients on OpenShift Virtualization |
| `demo-system-roles/` | RHEL System Roles: host registration, Cockpit, monitoring |
| `demo-windows-vm/` | Windows Server golden image via Tekton pipeline on OpenShift Virtualization |
| `demo-cve-remediation/` | AAP + Automation Orchestrator CVE remediation with Lightspeed MCP |

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

- Each demo has its own README.md (human docs) and one agent context file: `AGENTS.md`. Cursor and Antigravity read that file. `CLAUDE.md` is a symlink to it for Claude Code. Edit `AGENTS.md` only.
- Task workflows that should auto-trigger live as project skills under the demo’s `.cursor/skills/` and are registered at repo root via symlink into `.cursor/skills/` (and `.claude/skills/` when Claude Code should see them too)
- Credentials go in `.env` (copied from `.env.sample`, gitignored)
- Most OpenShift demos use kustomize base/overlay patterns
- Ansible demos use `ansible-navigator` with containerized execution environments

## Project skills

| Skill | Demo |
|---|---|
| `bootc-fedora-desktop` | `demo-bootc-fedora-desktop/` |
| `fedora-silverblue` | `demo-fedora-silverblue/` |
| `cve-remediation-demo` | `demo-cve-remediation/` |
| `ao-cve-lab` | `demo-aiops/aiops-orchestrator/` |
