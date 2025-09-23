# RHEL 10 Secondary IPs management

There are several options for secondary IP management described in [this overview](./network-management-overview.md).

Lets focus on 2 options here.

First simplistic using NetworkManager dispatcher scripts to add required IPs.

Second more complex, but abstracting the implementation for end user and oppening door for more automation so ease migration of service between servers.

## Network Manager Dispatcher

This option is similar to previously supported way of manual file edit and bringing up the interface.

Currently all the IP addresses are in a single file, but the dispatcher file could load files defined in certain path.

For example lets create an connection for secondary network interface by creating following file:

```ini
# /etc/NetworkManager/system-connections/eth-secondary.nmconnection
[connection]
id=eth-secondary
type=ethernet
interface-name=enp2s0
autoconnect=yes

[ethernet]

[ipv4]
method=manual
# Multiple addresses separated by semicolons
addresses=192.168.200.11/24
# Optional: specify gateway if needed
gateway=192.168.200.1
# Optional: DNS servers
dns=8.8.8.8;8.8.4.4;

[ipv6]
method=disabled
```

And set proper permissions:

```bash
chmod 600 /etc/NetworkManager/system-connections/eth-secondary.nmconnection
```

Add dispatcher script to add ip addresses:

```bash
#!/bin/bash
# /etc/NetworkManager/dispatcher.d/50-add-aliases

INTERFACE=$1
ACTION=$2

if [[ "$INTERFACE" == "enp2s0" && "$ACTION" == "up" ]]; then
    # Add additional IPs when interface comes up
    ip addr add 192.168.200.24/24 dev enp2s0
    ip addr add 192.168.200.21/24 dev enp2s0
fi
```

Make the script executable:

```bash
sudo chmod +x /etc/NetworkManager/dispatcher.d/50-add-aliases
```

Now bring the interface up

```bash
nmcli con up eth-secondary
```

Show configured IP addresses

```bash
nmcli -g IP4.ADDRESS con show eth-secondary
```

To change the active IP addresses update the script */etc/NetworkManager/dispatcher.d/50-add-aliases* and run command

```bash
nmcli con up eth-secondary
```

## Self-service Automation approach

If looking more broadly on the problem, there is another better solution.

To implement it one would need:

- AAP
  - Group per application with group vars describing deployment and ip address
- automation to
  - deploy application
  - configure network
- [This gemini approach](https://gemini.google.com/app/e5f78f48a422ad03) could work for automation