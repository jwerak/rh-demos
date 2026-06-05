# CLAUDE.md

## Overview

Satellite + AAP integration demo. Older and less maintained -- not recently tested.

## Status

This demo depends on the "AAP2 Ansible & Smart Management Workshop" environment from demo.redhat.com. It is not self-contained.

## Setup Flow

1. Order the workshop environment from demo.redhat.com (Ansible Automation Platform 2 Smart Management)
2. Run a series of AAP Controller templates in sequence to set up the environment (see README.md for the full list)
3. Configure Satellite Host Groups with correct `remote_execution_ssh_user` per OS (centos for CentOS, ec2-user for RHEL)
4. Add SSH public key from `remote_execution_ssh_keys[0]` to managed hosts

## Files

- `README.md` - Setup instructions (this is the only file in the demo)

## Dependencies

- Red Hat Satellite (provisioned via demo.redhat.com)
- Ansible Automation Platform 2
- External repo: https://github.com/jwerak/demos.git (playbook: satellite-setup/setup.yml)
