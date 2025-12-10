# RH Demos

This repository contains a collection of demonstrations for various Red Hat technologies.

## Demos

Here is an overview of the available demos:

* [**AIOps**](./aiops/): This demo showcases AIOps capabilities, including integration with Ansible Automation Platform (AAP) and an agent-based approach for incident assistance.
  * [AIOps - AAP](./aiops/aiops-aap/): Speeds up the setup of an AAP demo for AIOps.
  * [AIOps - Agentic](./aiops/aiops-agent/): Demonstrates an agentic approach to AIOps with an Ops Assistant Agent.

* [**ACM Policies**](./demo-acm-policies/): This demo shows how to manage the lifecycle of operators using Red Hat Advanced Cluster Management (ACM) policies. It covers version pinning, controlled upgrades, and rollout management.

* [**Containerfile Demo**](./demo-containerfile/): This demo illustrates how to copy multiple files from the localhost to a container image while preserving directory structure and merging with the existing container filesystem.

* [**Network Manager**](./demo-network-manager/): This demo explores different options for managing secondary IP addresses in RHEL 10, including using NetworkManager dispatcher scripts and a self-service automation approach.

* [**Podman Build Push Run**](./demo-podman-build-push-run/): A simple demonstration of the container development workflow using Podman to build, push, and run a container image.

* [**Satellite**](./demo-satellite/): An introduction to Red Hat Satellite, although it's noted as being older and not recently tested.

* [**System Roles**](./demo-system-roles/): This demo showcases the use of RHEL System Roles for configuring and managing RHEL systems. It includes examples for registering hosts, installing Cockpit, and enabling monitoring.

## Unified Demo Deployment

This repository includes a unified Ansible playbook to deploy and manage the demos. The playbook is located in the `ansible-controller` directory and is designed to be run with `ansible-navigator`.

### Prerequisites

- `ansible-navigator` is installed.
- `podman` is installed.
- For demos requiring VMs: `libvirt` is installed and running.

### Usage

1.  Navigate to the `ansible-controller` directory:
    ```bash
    cd ansible-controller
    ```

2.  Run `ansible-navigator`. You will be prompted to enter the name of the demo you want to deploy.

    For demos that **do not** require VM provisioning (e.g., `demo-containerfile`):
    ```bash
    ansible-navigator run --extra-vars "demo_name=demo-containerfile"
    ```

    For demos that **do** require VM provisioning (e.g., `demo-network-manager`):
    ```bash
    ansible-navigator run -i inventory/demo-network-manager.yml --extra-vars "demo_name=demo-network-manager provisioner=libvirt"
    ```

    The available demos are:
    - `aiops`
    - `demo-acm-policies`
    - `demo-containerfile`
    - `demo-network-manager`
    - `demo-podman-build-push-run`
    - `demo-satellite`
    - `demo-system-roles`
