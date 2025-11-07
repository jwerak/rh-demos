# AIOps from RH Demo portal

Speed up setup of AAP demo for AIOps.

## Order

Item listed under name [Introduction to AI Driven Ansible Automation](https://catalog.demo.redhat.com/catalog?search=aiops&item=babylon-catalog-prod%2Fsandboxes-gpte.ai-driven-ansible-automation.prod)

![AIOps](./pics/aiops.png)

## Configure

Copy *.env.sample* to *.env* and fill in controller login info.

```bash
source .env
ansible-navigator run playbooks/aiops-workflows.yml --penv CONTROLLER_OAUTH_TOKEN --penv CONTROLLER_HOST
```

### Controller Manual updates - tmp

- Add this repo as another project
- Job Template to use monitoring-setup playbook.
- Disable node1 filebeat
  - `systemctl stop filebeat`
