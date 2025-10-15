# Showcase RHEL System Roles

Assumptions

- Using execution environment with [RHEL System Roles](https://access.redhat.com/articles/3050101).

## Create VMs for demo

```bash
ansible-navigator run jwerak.cloud.libvirt_vm_setup -e target=lab_hosts
```

## Read inventory info

```bash
ansible-navigator inventory
```

## Register hosts

```bash
ansible-navigator run playbooks/rhc.yml -e @./vault.yml
```

## Install Cockpit

```bash
ansible-navigator run playbooks/cockpit.yml
```

## Enable Monitoring


## Install Cockpit

```bash
ansible-navigator run playbooks/monitoring.yml
```