# IP alias setup using multiple ifcf files

## Setup libvirt lab

Create secondary network

```bash
sudo virsh net-define ./libvirt/network-internal.xml

# Start the network
sudo virsh net-start network-internal

# Set the network to start automatically on host boot
sudo virsh net-autostart network-internal

# Verify the network is active and running
sudo virsh net-list
```

Create VMs Using Ansible:

review the [inventory file](./hosts_and_groups/inventory.yml) and run

```bash
ansible-navigator run jwerak.cloud.libvirt_vm_setup -e target=network_test_nodes
```

Get IPs of created VMs

```bash
sudo virsh list --all --name | grep '^00-' | xargs -I{} sudo virsh domifaddr {} --source agent
```

## Assign IP address

To configure the `eth1` interface on RHEL 7 using the `ifcfg` file notation, create a file named `/etc/sysconfig/network-scripts/ifcfg-eth1` inside the VM with the following content:

*/etc/sysconfig/network-scripts/ifcfg-eth1*:

```env
DEVICE=eth1
BOOTPROTO=none
ONBOOT=yes
PREFIX=24
IPADDR1=192.168.200.11
IPADDR2=192.168.200.12
```

*/etc/sysconfig/network-scripts/ifcfg-eth1:0*:

```env
DEVICE=eth1:0
IPADDR=192.168.200.13
```

To apply the new network script and bring up the `eth1` interface, run the following command inside the VM: `ifup eth1`

## Cleanup environment

```bash
# Make it executable
chmod +x ./cleanup.sh

# Run with sudo (required for libvirt operations)
sudo ./cleanup.sh
```

The script includes safety checks and will skip components that don't exist, so it's safe to run multiple times. It also provides clear output about what actions are being performed.
