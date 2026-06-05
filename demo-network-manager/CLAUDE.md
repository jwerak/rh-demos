# CLAUDE.md

## Overview

RHEL 10 NetworkManager IP alias management demo. Shows how to assign multiple IP addresses to network interfaces using NetworkManager (replacing legacy ifcfg scripts) and automate it with Ansible.

## Structure

All content lives under `alias-ip-assignments/`:
- `00_initial_setup/` - Libvirt lab provisioning, legacy ifcfg baseline demo (RHEL 7 style)
- `01_network_manager/` - RHEL 10 NetworkManager approach with Ansible automation
  - `ansible/roles/ip_configuration/` - Role to apply IP configs via nmcli
  - `ansible/roles/ip_inventory_validator/` - Role to validate IP conflicts in inventory
  - `ansible/playbooks/set-network.yml` - Apply network configuration
  - `ansible/playbooks/validate-ip-conflicts.yml` - Pre-flight IP conflict check
  - `hosts_and_groups/group_vars/` - Per-group IP assignments (web_servers, db_servers)

## Key Commands

```bash
cd alias-ip-assignments

# Provision VMs via libvirt
ansible-navigator run jwerak.cloud.libvirt_vm_setup -e target=network_test_nodes -i 01_network_manager/hosts_and_groups

# Apply network configuration
ansible-navigator run 01_network_manager/ansible/playbooks/set-network.yml

# Validate IP conflicts
ansible-navigator run 01_network_manager/ansible/playbooks/validate-ip-conflicts.yml
```

## Key Tools

- `ansible-navigator` with EE image `quay.io/jwerak/ansible-ee-base:latest`
- Libvirt for VM provisioning (requires `jwerak.cloud` Ansible collection)
- IP assignments defined in inventory group_vars, not in playbooks
