# Red Hat Demos

## Podman build/ship/run

[podman](./podman-build-push-run/)

## Satellite intro

### Setup

- Order demo [Ansible Automation Platform 2 Ansible & Smart Management Workshop](https://demo.redhat.com/catalog?item=babylon-catalog-prod/ansiblebu.aap2-workshop-smart-mgmt.prod&utm_source=webapp&utm_medium=share-link)
  - Official [documentation workshop guide](https://aap2.demoredhat.com/exercises/ansible_smart_mgmt/0-setup/)
- Call Automation Controller Templates to setup env
  - *5 - SETUP / Controller*
  - *SATELLITE / RHEL - Publish Content View*
    - Survey: `RHEL7`
  - *SERVER / RHEL7 - Register*
    - Survey: `node`, `Dev`
  - *SERVER / CentOS7 - Register*
    - Survey: `node`, `Dev`
  - *EC2 / Set instance tag - AnsibleGroup*
  - *CONTROLLER / Update inventories via dynamic sources*
    - Survey: *RHEL7*, *Dev*
    - Survey: *CentOS7*, *Dev*

#### Enable Remote execution on Hosts

- Add pub ssh key to authorized keys of given user
  - Get the key from host ansible inventory `remote_execution_ssh_keys[0]`
  - Use the key and create AAP Temlate from repo: https://github.com/jwerak/demos.git
  - Create and execute the template to add the key
    - Playbook: *satellite-setup/setup.yml*
    - Credentials: *Workshop Credentials*
    - Inventory: *Workshop Inventory*
    - Limit: `node*`
- Create Satellite Host Groups (RHEL and CentOS) and add correct remote user name:
  -  Satellite -> Configure -> Host Groups
     -  CentOS  -> Parameters -> `remote_execution_ssh_user = centos`
     -  RHEL    -> Parameters -> `remote_execution_ssh_user = ec2-user`
