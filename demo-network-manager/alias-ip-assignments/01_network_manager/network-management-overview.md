# IP alias using Network Manager

## Overview

In RHEL 10, NetworkManager is the primary service for managing network configurations. Multiple IP addresses (alias IPs) can be assigned to a single network interface using various methods. This guide covers all available approaches and provides best practices for managing IP address assignments using Ansible.

## Table of Contents

1. [Using nmcli (Command Line)](#using-nmcli-command-line)
2. [Using NetworkManager Configuration Files](#using-networkmanager-configuration-files)
3. [Using nmstate](#using-nmstate)
4. [Using RHEL System Roles](#using-rhel-system-roles)
5. [Other Methods](#other-methods)
6. [Unified Ansible Solution for Multi-Persona IP Management](#unified-ansible-solution-for-multi-persona-ip-management)

## Using nmcli (Command Line)

The `nmcli` tool is the primary command-line interface for NetworkManager and provides several ways to configure multiple IP addresses.

### Method 1: Multiple IP Addresses on Single Connection

```bash
# Create a new connection with primary IP
sudo nmcli connection add \
    con-name eth1-multi \
    ifname eth1 \
    type ethernet \
    ipv4.method manual \
    ipv4.addresses "192.168.200.11/24"

# Add additional IP addresses to the same connection
sudo nmcli connection modify eth1-multi +ipv4.addresses "192.168.200.12/24"
sudo nmcli connection modify eth1-multi +ipv4.addresses "192.168.200.13/24"
sudo nmcli connection modify eth1-multi +ipv4.addresses "192.168.200.14/24"

# Activate the connection
sudo nmcli connection up eth1-multi
```

### Method 3: Interactive Mode

```bash
# Enter interactive editor
sudo nmcli connection edit eth1-multi

# In the nmcli prompt:
nmcli> set ipv4.method manual
nmcli> set ipv4.addresses 192.168.200.11/24,192.168.200.12/24,192.168.200.13/24
nmcli> print ipv4
nmcli> save
nmcli> activate
nmcli> quit
```

### Viewing Configuration

```bash
# Show all IP addresses on an interface
ip addr show eth1

# Show NetworkManager connection details
nmcli connection show eth1-multi

# Show detailed IP configuration
nmcli -p connection show eth1-multi | grep ipv4.addresses
```

## Using NetworkManager Configuration Files

NetworkManager stores connection profiles in `/etc/NetworkManager/system-connections/`. These are INI-style files that can be edited directly.

### Example Configuration File

Create or edit `/etc/NetworkManager/system-connections/eth1-multi.nmconnection`:

```ini
[connection]
id=eth1-multi
uuid=550f1b2e-d0dd-4358-8d94-12345678abcd
type=ethernet
interface-name=eth1
autoconnect=yes

[ethernet]

[ipv4]
method=manual
# Multiple addresses separated by semicolons
addresses=192.168.200.11/24;192.168.200.12/24;192.168.200.13/24;192.168.200.14/24
# Optional: specify gateway if needed
gateway=192.168.200.1
# Optional: DNS servers
dns=8.8.8.8;8.8.4.4;

[ipv6]
method=disabled
```

### Apply Configuration

```bash
# Set proper permissions (important!)
sudo chmod 600 /etc/NetworkManager/system-connections/eth1-multi.nmconnection

# Reload NetworkManager to recognize the new file
sudo nmcli connection reload

# Activate the connection
sudo nmcli connection up eth1-multi
```

### Key File Format Notes

- **addresses**: Format is `ip/prefix;ip/prefix;...`
- **address-data**: Alternative format for more complex setups (JSON array)
- **routes**: Can specify static routes if needed
- **dns**: DNS servers separated by semicolons

## Using NetworkManager Dispatcher Scripts

For dynamic IP assignment based on events, create scripts in `/etc/NetworkManager/dispatcher.d/`:

```bash
#!/bin/bash
# /etc/NetworkManager/dispatcher.d/50-add-aliases

INTERFACE=$1
ACTION=$2

if [[ "$INTERFACE" == "enp2s0" && "$ACTION" == "up" ]]; then
    # Add additional IPs when interface comes up
    ip addr add 192.168.200.20/24 dev enp2s0
    ip addr add 192.168.200.21/24 dev enp2s0
fi
```

Make executable:

```bash
sudo chmod +x /etc/NetworkManager/dispatcher.d/50-add-aliases
```

## Using nmstate

nmstate provides a declarative API for network configuration using YAML. It's particularly useful for infrastructure-as-code approaches.

### Install nmstate

```bash
sudo dnf install -y nmstate
```

### Create YAML Configuration

Create `eth1-aliases.yml`:

```yaml
---
interfaces:
  - name: eth1
    type: ethernet
    state: up
    ipv4:
      enabled: true
      # Multiple addresses defined as a list
      address:
        - ip: 192.168.200.11
          prefix-length: 24
        - ip: 192.168.200.12
          prefix-length: 24
        - ip: 192.168.200.13
          prefix-length: 24
        - ip: 192.168.200.14
          prefix-length: 24
      dhcp: false
    ipv6:
      enabled: false
```

### Apply nmstate Configuration

```bash
# Preview changes (dry-run)
sudo nmstatectl apply --no-commit eth1-aliases.yml

# Apply configuration
sudo nmstatectl apply eth1-aliases.yml

# Verify current state
sudo nmstatectl show eth1
```

### Complex Example with Routes

```yaml
---
interfaces:
  - name: eth1
    type: ethernet
    state: up
    ipv4:
      enabled: true
      address:
        - ip: 192.168.200.11
          prefix-length: 24
        - ip: 192.168.200.12
          prefix-length: 24
        - ip: 192.168.200.13
          prefix-length: 24
      dhcp: false
routes:
  config:
    - destination: 10.0.0.0/8
      next-hop-address: 192.168.200.1
      next-hop-interface: eth1
dns-resolver:
  config:
    server:
      - 8.8.8.8
      - 8.8.4.4
```

## Using RHEL System Roles

RHEL System Roles provide an officially supported, consistent interface to configure RHEL systems using Ansible. The `rhel-system-roles.network` role can configure multiple IP addresses on interfaces.

### Install RHEL System Roles

```bash
# On RHEL 10
sudo dnf install -y rhel-system-roles

# Verify installation
ls /usr/share/ansible/roles/rhel-system-roles.network/
```

### Basic Configuration with Multiple IPs

Create a playbook `network-aliases-system-role.yml`:

```yaml
---
- name: Configure network interface with multiple IPs using RHEL System Role
  hosts: network_test_nodes
  become: yes

  vars:
    network_connections:
      - name: eth1-multi
        type: ethernet
        interface_name: eth1
        state: up
        autoconnect: yes
        ip:
          dhcp4: no
          address:
            - 192.168.200.11/24
            - 192.168.200.12/24
            - 192.168.200.13/24
            - 192.168.200.14/24
          gateway4: 192.168.200.1
          dns:
            - 8.8.8.8
            - 8.8.4.4

  roles:
    - rhel-system-roles.network
```

### Advanced Configuration with Routes and Multiple Interfaces

```yaml
---
- name: Advanced network configuration with RHEL System Role
  hosts: network_test_nodes
  become: yes

  vars:
    network_connections:
      # Primary interface with multiple IPs
      - name: primary-connection
        type: ethernet
        interface_name: eth0
        state: up
        autoconnect: yes
        ip:
          dhcp4: yes

      # Secondary interface with alias IPs
      - name: eth1-aliases
        type: ethernet
        interface_name: eth1
        state: up
        autoconnect: yes
        ip:
          dhcp4: no
          address:
            - 192.168.200.11/24
            - 192.168.200.12/24
            - 192.168.200.13/24
            - 192.168.200.14/24
          gateway4: 192.168.200.1
          dns:
            - 8.8.8.8
            - 8.8.4.4
          dns_search:
            - example.com
          route:
            - network: 10.0.0.0
              prefix: 8
              gateway: 192.168.200.1
              metric: 100
            - network: 172.16.0.0
              prefix: 16
              gateway: 192.168.200.1

      # Bond interface example with multiple IPs
      - name: bond0
        type: bond
        interface_name: bond0
        state: up
        autoconnect: yes
        ip:
          dhcp4: no
          address:
            - 192.168.100.10/24
            - 192.168.100.11/24
            - 192.168.100.12/24
        bond:
          mode: active-backup
          miimon: 100

      - name: bond0-slave-1
        type: ethernet
        interface_name: eth2
        controller: bond0
        state: up

      - name: bond0-slave-2
        type: ethernet
        interface_name: eth3
        controller: bond0
        state: up

  roles:
    - rhel-system-roles.network
```

### Using with Dynamic Variables

```yaml
---
- name: Configure network with dynamic IP assignments
  hosts: network_test_nodes
  become: yes

  vars:
    base_network: "192.168.200"
    ip_assignments:
      web_team:
        - 11
        - 12
        - 13
      db_team:
        - 20
        - 21
      monitoring_team:
        - 30
        - 31
        - 32

    # Build address list dynamically
    all_addresses: >-
      {%- set addresses = [] -%}
      {%- for team, ips in ip_assignments.items() -%}
        {%- for ip in ips -%}
          {%- set _ = addresses.append(base_network + '.' + ip|string + '/24') -%}
        {%- endfor -%}
      {%- endfor -%}
      {{ addresses }}

    network_connections:
      - name: eth1-multi-team
        type: ethernet
        interface_name: eth1
        state: up
        autoconnect: yes
        ip:
          dhcp4: no
          address: "{{ all_addresses }}"
          gateway4: "{{ base_network }}.1"

  roles:
    - rhel-system-roles.network
```

### Persisting Configuration Across Reboots

The RHEL System Role automatically ensures configurations persist across reboots by creating appropriate NetworkManager connection profiles. You can verify this:

```yaml
- name: Verify persistent configuration
  hosts: network_test_nodes
  become: yes

  tasks:
    - name: Show NetworkManager connections
      command: nmcli connection show
      register: nm_connections

    - name: Display connections
      debug:
        var: nm_connections.stdout_lines

    - name: Verify IP addresses persist
      command: ip addr show eth1
      register: ip_output

    - name: Display IP configuration
      debug:
        var: ip_output.stdout_lines
```

### Integration with Firewall Rules

RHEL System Roles can be combined for comprehensive configuration:

```yaml
---
- name: Configure network and firewall together
  hosts: network_test_nodes
  become: yes

  vars:
    network_connections:
      - name: eth1-services
        type: ethernet
        interface_name: eth1
        state: up
        ip:
          dhcp4: no
          address:
            - 192.168.200.11/24  # Web service
            - 192.168.200.12/24  # Database service
            - 192.168.200.13/24  # Monitoring

    firewall:
      - service: http
        source: 192.168.200.0/24
        zone: internal
        state: enabled
        permanent: yes

  roles:
    - rhel-system-roles.network
    - rhel-system-roles.firewall
```

### Benefits of RHEL System Roles

1. **Official Support**: Backed by Red Hat with regular updates
2. **Version Compatibility**: Works across RHEL 7, 8, 9, and 10
3. **Idempotent**: Safe to run multiple times
4. **Comprehensive**: Handles complex networking scenarios
5. **Integration**: Works well with other RHEL System Roles
6. **Best Practices**: Implements Red Hat's recommended configurations

### Troubleshooting

```yaml
- name: Debug network configuration
  hosts: network_test_nodes
  become: yes

  tasks:
    - name: Gather network facts
      setup:
        gather_subset:
          - network

    - name: Show ansible network facts
      debug:
        var: ansible_facts.interfaces

    - name: Test role with check mode
      include_role:
        name: rhel-system-roles.network
      check_mode: yes
      vars:
        network_connections:
          - name: test-connection
            type: ethernet
            interface_name: eth1
            ip:
              address:
                - 192.168.200.50/24
```

## Other Methods

### 1. systemd-networkd (Alternative to NetworkManager)

While NetworkManager is default in RHEL 10, systemd-networkd can be used as an alternative.

Create `/etc/systemd/network/25-eth1.network`:

```ini
[Match]
Name=eth1

[Network]
Address=192.168.200.11/24
Address=192.168.200.12/24
Address=192.168.200.13/24
Address=192.168.200.14/24
Gateway=192.168.200.1
DNS=8.8.8.8
```

Enable and use:

```bash
# Disable NetworkManager for this interface
sudo nmcli device set eth1 managed no

# Enable systemd-networkd
sudo systemctl enable --now systemd-networkd
```

### 2. Traditional ip Command (Temporary)

For temporary alias IPs (lost on reboot):

```bash
# Add IP addresses
sudo ip addr add 192.168.200.11/24 dev eth1
sudo ip addr add 192.168.200.12/24 dev eth1
sudo ip addr add 192.168.200.13/24 dev eth1

# With labels (traditional alias style)
sudo ip addr add 192.168.200.14/24 dev eth1 label eth1:0
sudo ip addr add 192.168.200.15/24 dev eth1 label eth1:1

# Bring interface up
sudo ip link set eth1 up
```



## Unified Ansible Solution for Multi-Persona IP Management

This section presents a comprehensive, production-ready Ansible solution that combines RHEL System Roles with multi-persona IP management. This approach allows multiple teams to manage their IP assignments independently while using Red Hat's officially supported configuration methods.

### Solution Overview

The solution provides:

- **Team-based IP management**: Each team maintains their own IP assignment files
- **Automatic merging**: IP assignments from all teams are automatically combined
- **Conflict detection**: Built-in checks for IP conflicts and overlaps
- **Multiple backend support**: Can use RHEL System Roles, nmstate, or nmcli
- **Audit trail**: Complete Git history of who requested which IPs
- **Validation**: Pre-flight checks ensure configurations are valid
- **Rollback capability**: Easy to revert changes if issues occur

### Complete Directory Structure

```text
ansible-ip-management/
├── ansible.cfg
├── requirements.yml
├── inventories/
│   └── production/
│       ├── hosts.yml
│       └── group_vars/
│           ├── all.yml
│           └── network_test_nodes.yml
├── roles/
│   ├── ip_merge/
│   │   ├── tasks/main.yml
│   │   ├── defaults/main.yml
│   │   └── templates/
│   │       └── merged_report.j2
│   └── network_config/
│       ├── tasks/main.yml
│       ├── defaults/main.yml
│       ├── handlers/main.yml
│       ├── templates/
│       │   ├── nmconnection.j2
│       │   └── nmstate.j2
│       └── vars/main.yml
├── persona_configs/
│   ├── README.md
│   ├── team_web.yml
│   ├── team_database.yml
│   ├── team_monitoring.yml
│   └── team_infrastructure.yml
├── playbooks/
│   ├── configure_network.yml
│   ├── validate_ips.yml
│   ├── report_assignments.yml
│   └── rollback_network.yml
└── scripts/
    ├── validate_ip_conflicts.py
    └── generate_team_template.sh
```

### Core Configuration Files

#### ansible.cfg

```ini
[defaults]
host_key_checking = False
retry_files_enabled = False
interpreter_python = auto_silent
collections_paths = ~/.ansible/collections:/usr/share/ansible/collections
roles_path = roles:~/.ansible/roles:/usr/share/ansible/roles
```

#### requirements.yml

```yaml
---
collections:
  - name: redhat.rhel_system_roles
    version: ">=1.20.0"
  - name: ansible.posix
  - name: community.general

roles: []
```

#### inventories/production/hosts.yml

```yaml
---
all:
  children:
    network_test_nodes:
      hosts:
        server01:
          ansible_host: 192.168.100.11
        server02:
          ansible_host: 192.168.100.12
        server03:
          ansible_host: 192.168.100.13
```

#### inventories/production/group_vars/all.yml

```yaml
---
# Global configuration
network_backend: rhel_system_roles  # Options: rhel_system_roles, nmstate, nmcli
network_prefix: 24
network_gateway: 192.168.200.1
network_dns_servers:
  - 8.8.8.8
  - 8.8.4.4

# IP conflict detection
enable_conflict_detection: true
reserved_ip_ranges:
  - start: 192.168.200.1
    end: 192.168.200.10
    description: "Network infrastructure"

# Backup settings
create_backup: true
backup_dir: /var/backups/network-configs
```

### Persona Configuration Files

#### persona_configs/team_web.yml

```yaml
---
team_name: web
contact_email: webteam@example.com
ip_assignments:
  - host: server01
    interface: eth1
    addresses:
      - ip: 192.168.200.11
        description: "Web Server Primary"
        service: nginx
        port: 80
      - ip: 192.168.200.12
        description: "Web Server Secondary"
        service: nginx
        port: 443
  - host: server02
    interface: eth1
    addresses:
      - ip: 192.168.200.13
        description: "Load Balancer VIP"
        service: haproxy
```

#### persona_configs/team_database.yml

```yaml
---
team_name: database
contact_email: dbteam@example.com
ip_assignments:
  - host: server01
    interface: eth1
    addresses:
      - ip: 192.168.200.20
        description: "PostgreSQL Primary"
        service: postgresql
        port: 5432
      - ip: 192.168.200.21
        description: "PostgreSQL Replica"
        service: postgresql
        port: 5432
  - host: server03
    interface: eth1
    addresses:
      - ip: 192.168.200.22
        description: "MongoDB Cluster"
        service: mongodb
        port: 27017
```

### Ansible Roles

#### roles/ip_merge/defaults/main.yml

```yaml
---
persona_dir: "{{ playbook_dir }}/../persona_configs"
output_file: "{{ playbook_dir }}/../inventories/production/group_vars/network_aliases.yml"
validate_conflicts: true
generate_report: true
```

#### roles/ip_merge/tasks/main.yml

```yaml
---
- name: Find all persona configuration files
  find:
    paths: "{{ persona_dir }}"
    patterns: "team_*.yml"
  register: persona_files

- name: Load all persona configurations
  include_vars:
    file: "{{ item.path }}"
    name: "persona_{{ item.path | basename | regex_replace('\\.yml$', '') }}"
  loop: "{{ persona_files.files }}"
  loop_control:
    label: "{{ item.path | basename }}"

- name: Initialize data structures
  set_fact:
    merged_config: {}
    all_ips: []
    ip_conflicts: []

- name: Merge configurations and collect all IPs
  include_tasks: merge_single_persona.yml
  vars:
    persona_name: "{{ item.path | basename | regex_replace('\\.yml$', '') }}"
    persona_data: "{{ lookup('vars', 'persona_' + persona_name) }}"
  loop: "{{ persona_files.files }}"
  loop_control:
    label: "{{ item.path | basename }}"

- name: Check for IP conflicts
  set_fact:
    ip_conflicts: "{{ ip_conflicts + [item] }}"
  when: all_ips | select('equalto', item) | list | length > 1
  loop: "{{ all_ips | unique }}"

- name: Fail if conflicts detected
  fail:
    msg: "IP conflicts detected: {{ ip_conflicts | join(', ') }}"
  when:
    - validate_conflicts | bool
    - ip_conflicts | length > 0

- name: Save merged configuration
  copy:
    content: "{{ {'network_aliases': merged_config} | to_nice_yaml }}"
    dest: "{{ output_file }}"
    backup: yes

- name: Generate assignment report
  template:
    src: merged_report.j2
    dest: "{{ output_file | dirname }}/ip_assignment_report.txt"
  when: generate_report | bool
```

#### roles/network_config/defaults/main.yml

```yaml
---
# Backend selection
network_backend: rhel_system_roles  # Options: rhel_system_roles, nmstate, nmcli

# Backup settings
backup_enabled: true
backup_path: /var/backups/network-configs

# RHEL System Roles specific settings
rhel_network_connections: []

# nmstate specific settings
nmstate_config: {}

# Common network settings
network_prefix: 24
network_gateway: ""
network_dns: []
```

#### roles/network_config/tasks/main.yml

```yaml
---
- name: Validate network backend selection
  assert:
    that:
      - network_backend in ['rhel_system_roles', 'nmstate', 'nmcli']
    fail_msg: "Invalid network_backend: {{ network_backend }}"

- name: Create backup directory
  file:
    path: "{{ backup_path }}"
    state: directory
    mode: '0750'
  when: backup_enabled | bool

- name: Backup current network configuration
  include_tasks: backup_config.yml
  when: backup_enabled | bool

- name: Configure using RHEL System Roles
  include_tasks: configure_rhel_system_roles.yml
  when: network_backend == 'rhel_system_roles'

- name: Configure using nmstate
  include_tasks: configure_nmstate.yml
  when: network_backend == 'nmstate'

- name: Configure using nmcli
  include_tasks: configure_nmcli.yml
  when: network_backend == 'nmcli'

- name: Verify configuration
  include_tasks: verify_config.yml
  tags: verify
```

#### roles/network_config/tasks/configure_rhel_system_roles.yml

```yaml
---
- name: Build network connections for RHEL System Roles
  set_fact:
    rhel_network_connections: >-
      {% set connections = [] %}
      {% for interface, addresses in network_aliases[inventory_hostname].items() %}
      {% set conn = {
        'name': interface + '-multi',
        'type': 'ethernet',
        'interface_name': interface,
        'state': 'up',
        'autoconnect': true,
        'ip': {
          'dhcp4': false,
          'address': addresses | map(attribute='ip') | map('regex_replace', '$', '/' + network_prefix|string) | list,
          'gateway4': network_gateway,
          'dns': network_dns_servers
        }
      } %}
      {% set _ = connections.append(conn) %}
      {% endfor %}
      {{ connections }}
  when: inventory_hostname in network_aliases

- name: Apply configuration using RHEL System Roles
  include_role:
    name: redhat.rhel_system_roles.network
  vars:
    network_connections: "{{ rhel_network_connections }}"
  when: rhel_network_connections | length > 0
```

### Main Playbooks

#### playbooks/configure_network.yml

```yaml
---
- name: Configure network aliases across infrastructure
  hosts: localhost
  gather_facts: no
  tasks:
    - name: Merge IP assignments from all personas
      include_role:
        name: ip_merge

- name: Apply network configuration
  hosts: network_test_nodes
  become: yes
  pre_tasks:
    - name: Display configuration backend
      debug:
        msg: "Using backend: {{ network_backend }}"

  roles:
    - network_config

  post_tasks:
    - name: Show applied configuration
      command: ip addr show
      register: ip_output
      changed_when: false

    - name: Display IP addresses
      debug:
        var: ip_output.stdout_lines
      tags: verify
```

#### playbooks/validate_ips.yml

```yaml
---
- name: Validate IP assignments before applying
  hosts: localhost
  gather_facts: no

  tasks:
    - name: Run IP merge with validation
      include_role:
        name: ip_merge
      vars:
        validate_conflicts: true

    - name: Check for reserved IP usage
      script: ../scripts/validate_ip_conflicts.py
      args:
        chdir: "{{ playbook_dir }}"
      register: validation_result

    - name: Display validation results
      debug:
        var: validation_result.stdout_lines
```

#### playbooks/report_assignments.yml

```yaml
---
- name: Generate IP assignment report
  hosts: localhost
  gather_facts: no

  tasks:
    - name: Load merged configuration
      include_vars:
        file: "{{ playbook_dir }}/../inventories/production/group_vars/network_aliases.yml"

    - name: Generate comprehensive report
      template:
        src: ../roles/ip_merge/templates/merged_report.j2
        dest: "{{ playbook_dir }}/../reports/ip_assignments_{{ ansible_date_time.date }}.html"

    - name: Create CSV export
      copy:
        content: |
          Host,Interface,IP Address,Team,Description,Service,Port
          {% for host, interfaces in network_aliases.items() %}
          {% for interface, addresses in interfaces.items() %}
          {% for addr in addresses %}
          {{ host }},{{ interface }},{{ addr.ip }},{{ addr.team | default('Unknown') }},{{ addr.description | default('') }},{{ addr.service | default('') }},{{ addr.port | default('') }}
          {% endfor %}
          {% endfor %}
          {% endfor %}
        dest: "{{ playbook_dir }}/../reports/ip_assignments_{{ ansible_date_time.date }}.csv"
```

### Helper Scripts

#### scripts/validate_ip_conflicts.py

```python
#!/usr/bin/env python3

import yaml
import ipaddress
import sys
from pathlib import Path

def load_config():
    config_file = Path("../inventories/production/group_vars/all.yml")
    with open(config_file, 'r') as f:
        return yaml.safe_load(f)

def check_reserved_ranges(ip, reserved_ranges):
    ip_obj = ipaddress.ip_address(ip)
    for range_def in reserved_ranges:
        start = ipaddress.ip_address(range_def['start'])
        end = ipaddress.ip_address(range_def['end'])
        if start <= ip_obj <= end:
            return range_def['description']
    return None

def main():
    config = load_config()
    network_aliases = yaml.safe_load(
        Path("../inventories/production/group_vars/network_aliases.yml").read_text()
    )

    conflicts = []

    for host, interfaces in network_aliases.get('network_aliases', {}).items():
        for interface, addresses in interfaces.items():
            for addr in addresses:
                ip = addr['ip']
                conflict = check_reserved_ranges(ip, config['reserved_ip_ranges'])
                if conflict:
                    conflicts.append(f"{ip} conflicts with reserved range: {conflict}")

    if conflicts:
        print("IP Conflicts Detected:")
        for conflict in conflicts:
            print(f"  - {conflict}")
        sys.exit(1)
    else:
        print("No IP conflicts detected")
        sys.exit(0)

if __name__ == "__main__":
    main()
```

### Usage Instructions

#### Initial Setup

```bash
# Clone the repository
git clone <your-repo>
cd ansible-ip-management

# Install Ansible collections
ansible-galaxy collection install -r requirements.yml

# Configure your inventory
vim inventories/production/hosts.yml
```

#### Standard Workflow

1. **Add new IP assignments**:

```bash
# Create a new team file
cp persona_configs/team_web.yml persona_configs/team_newteam.yml
vim persona_configs/team_newteam.yml
```

2. **Validate assignments**:

```bash
# Check for conflicts before applying
ansible-playbook playbooks/validate_ips.yml
```

3. **Apply configuration**:

```bash
# Apply to all nodes (default: uses RHEL System Roles)
ansible-playbook playbooks/configure_network.yml

# Use different backend
ansible-playbook playbooks/configure_network.yml -e network_backend=nmstate

# Apply to specific hosts
ansible-playbook playbooks/configure_network.yml --limit server01
```

4. **Generate reports**:

```bash
# Create assignment reports
ansible-playbook playbooks/report_assignments.yml

# View the generated report
ls -la reports/
```

#### Advanced Usage

##### Switching Configuration Backends

```bash
# Use nmstate backend
ansible-playbook playbooks/configure_network.yml \
  -e network_backend=nmstate

# Use nmcli backend
ansible-playbook playbooks/configure_network.yml \
  -e network_backend=nmcli

# Force RHEL System Roles (default)
ansible-playbook playbooks/configure_network.yml \
  -e network_backend=rhel_system_roles
```

##### Dry Run Mode

```bash
# Check what would be changed
ansible-playbook playbooks/configure_network.yml --check --diff

# Validate only, no changes
ansible-playbook playbooks/validate_ips.yml
```

##### Rollback Changes

```bash
# Create rollback playbook
cat > playbooks/rollback_network.yml << 'EOF'
---
- name: Rollback network configuration
  hosts: network_test_nodes
  become: yes

  tasks:
    - name: Find backup files
      find:
        paths: "{{ backup_path }}"
        patterns: "*.backup"
        age: "-1d"
      register: backups

    - name: Restore from backup
      copy:
        src: "{{ item.path }}"
        dest: "{{ item.path | regex_replace('.backup$', '') }}"
        remote_src: yes
      loop: "{{ backups.files }}"

    - name: Reload network configuration
      command: nmcli connection reload

    - name: Restart NetworkManager
      systemd:
        name: NetworkManager
        state: restarted
EOF

ansible-playbook playbooks/rollback_network.yml
```

### Benefits of This Unified Approach

1. **Single Source of Truth**: All IP assignments managed in one place
2. **Multi-Backend Support**: Choose between RHEL System Roles, nmstate, or nmcli
3. **Team Autonomy**: Each team manages their own IP assignments
4. **Conflict Prevention**: Built-in validation prevents IP conflicts
5. **Audit Trail**: Complete history in Git
6. **Easy Rollback**: Automatic backups enable quick recovery
7. **Reporting**: Generate reports for compliance and documentation
8. **Scalability**: Easily handle hundreds of servers and IPs
9. **Red Hat Support**: Using official RHEL System Roles ensures support

### Troubleshooting Guide

#### Common Issues

1. **IP Conflicts**:

```bash
# Check current assignments
ansible-playbook playbooks/report_assignments.yml

# Validate without applying
ansible-playbook playbooks/validate_ips.yml
```

2. **Backend Issues**:

```bash
# Test RHEL System Roles
ansible-playbook playbooks/configure_network.yml \
  --limit server01 \
  -e network_backend=rhel_system_roles \
  --tags verify

# Test with verbose output
ansible-playbook playbooks/configure_network.yml -vvv
```

3. **Permission Issues**:

```bash
# Ensure proper sudo access
ansible all -m ping --become

# Check file permissions
ansible all -m file -a "path=/etc/NetworkManager/system-connections state=directory" --become
```

This unified solution provides a production-ready, scalable approach to managing multiple IP aliases across your RHEL infrastructure while maintaining separation of concerns and providing multiple configuration options.
