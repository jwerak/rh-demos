# IP Alias assignments

## Motivation

There was a possibility to merge multiple filets to single configuration of an network interface in ifcfg scripts.

## legacy ifcfg setup

As a baseline lets try how the network interface could've been configured using multiple alias files.

To bring up the env for this demo run this command:

```bash
ansible-navigator run jwerak.cloud.libvirt_vm_setup -e target=network_test_nodes -i 00_initial_setup/hosts_and_groups
```

See this [baseline demo](./00_initial_setup/README.md).

## RHEL 10 & NetworkManager Options

Lets have a look to configure same thing in RHEL 10 and suggest how to merge files togeter using ansible.

To bring up the env for this demo run this command:

```bash
ansible-navigator run jwerak.cloud.libvirt_vm_setup -e target=network_test_nodes -i 01_network_manager/hosts_and_groups
```

See detailed demo in next network [manager section](./01_network_manager/README.md)
