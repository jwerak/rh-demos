# CLAUDE.md

## Overview

RHEL System Roles demo for infrastructure automation: host registration, Cockpit web console, and monitoring setup.

## Structure

- `playbooks/rhc.yml` - Register hosts with Red Hat (requires vault.yml for credentials)
- `playbooks/cockpit.yml` - Install and configure Cockpit web console
- `playbooks/monitoring.yml` - Enable system monitoring
- `hosts_and_groups/` - Inventory and group variables
- `vault.yml` - Encrypted credentials (used with rhc.yml)
- `ansible-navigator.yml` - EE config (image: `quay.io/jwerak/ansible-ee-base:latest`)

## Key Commands

```bash
# Provision VMs (requires jwerak.cloud collection + libvirt)
ansible-navigator run jwerak.cloud.libvirt_vm_setup -e target=lab_hosts

# View inventory
ansible-navigator inventory

# Register hosts with Red Hat
ansible-navigator run playbooks/rhc.yml -e @./vault.yml

# Install Cockpit
ansible-navigator run playbooks/cockpit.yml

# Enable monitoring
ansible-navigator run playbooks/monitoring.yml
```

## Prerequisites

- Execution environment with RHEL System Roles installed
- Libvirt for VM provisioning
- `jwerak.cloud` Ansible collection (mounted from `../../ansible_collections/jwerak`)
- Vault password for `vault.yml` (contains registration credentials)
