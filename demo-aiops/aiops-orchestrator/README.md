# AIOps - Automation Orchestrator

Stand up Automation Orchestrator (AO) and run the workflows from the [Automation Orchestrator demos](https://ansible-tmm.github.io/aap-orchestrator-demos/) catalog.

Scenario write-ups live in [ansible-tmm/aap-orchestrator-demos](https://github.com/ansible-tmm/aap-orchestrator-demos). Each card on the catalog site links to its own guide. The RHEL CVE scenario is already implemented in this repo as [demo-cve-remediation](../../demo-cve-remediation/).

Two ways to get AO:

1. **Product Demos lab** (Red Hat Demo Platform) — the path used for these notes.
2. **Local `aap-demo`** — not tried here. Upstream documents a 16 GB CRC VM as the default.

## Product Demos lab

Order the lab from the [product-demos catalog item](https://catalog.demo.redhat.com/catalog/all?search=product-demos&item=babylon-catalog-prod%2Fenterprise.aap-product-demos-cnv-aap25.prod).

Walkthrough video: [How to run the AO demo](https://drive.google.com/file/d/1PcyEPkJ6nfOMoSuOzQL2QoqJtpiAXAFj/view).

In the lab AAP, launch these job templates in order:

1. **APD | Single demo setup**, use case **infrastructure**. Wait until the job finishes.
2. **Infrastructure | Automation Orchestrator | Install**.

The install job output contains the AO URL and login. Copy those into `.env`:

```bash
cp .env.sample .env
```

On a fresh lab both jobs still have to run: `APD | Single demo setup` with use case `infrastructure` (it also creates the `Cloud | AWS | *` templates), then `Infrastructure | Automation Orchestrator | Install`. The AO admin password is in secret `automation-orchestrator-initial-admin-password` in namespace `automation-orchestrator`.

## RHEL nodes

The cloud job templates are already on this AAP. They use the `AWS` and `APD Machine Credential` credentials. `Cloud | AWS | Create VM` tags instances so the `AWS Inventory` source can import them (`managed-by=aap-product-demos`, `apd=true`, hostname from the Name tag, `ansible_host` from the public IP, user `ec2-user`).

| Template | Survey variables this setup sends |
|---|---|
| `Cloud \| AWS \| Create VPC` | `create_vm_aws_region=us-east-2`, `aws_owner_tag=ao-demo` |
| `Cloud \| AWS \| Create Keypair` | `create_vm_aws_region=us-east-2`, `aws_key_name=aws-test-key` |
| `Cloud \| AWS \| Create VM` | one launch each for `cve-node1` (Dev), `cve-node2` (Prod), `cve-node3` (Prod), blueprint `rhel9`, image filter `RHEL-9.6.0_HVM-202506*` |

`playbooks/wire-lab-inventory.yml` then syncs AWS inventory and writes `lab-inventory` in organization `Ansible Product Demos (APD)`:

| AWS Name tag | Host | env | role | criticality |
|---|---|---|---|---|
| cve-node1 | node1 | dev | webserver | low |
| cve-node2 | node2 | production | application_server | high |
| cve-node3 | node3 | production | database | critical |

`.env` has `RHSM_ORG_ID`, `RHSM_ACTIVATION_KEY`, and the MaaS model (`AO_MODEL_BASE_URL`, `AO_MODEL_NAME`, `AO_MODEL_ACCESS_TOKEN`). The SSH private key for `aws-test-key` stays inside the AAP credential `APD Machine Credential`. Registration runs as a controller job with that credential, so a local copy of the key is not required.

An agent follows `.cursor/skills/ao-cve-lab/SKILL.md` to finish this lab. The AO screens that stay manual are in `.cursor/skills/ao-cve-lab/ui.md`.

`playbooks/configure-aap.yml` creates the controller objects for that path:

- credential type and credential `AO Lab RHSM` (injects `RHSM_ORG_ID` and `RHSM_ACTIVATION_KEY`)
- inventory `AO Orchestrator Localhost`
- git project `AO Orchestrator` (`https://github.com/jwerak/rh-demos.git`, branch `master`)
- job template `AO Lab | Wire inventory` (playbook `wire-lab-inventory.yml`, credential `AAP Credential`)
- job template `AO Lab | Register nodes` (playbook `register-rhel-nodes.yml`, credentials `APD Machine Credential` and `AO Lab RHSM`)
- job templates `CVE - Fetch and Commit`, `CVE - Sync and Deploy Remediation`, and `CVE - Notify Mattermost Investigation` (playbooks under `demo-cve-remediation/aap/playbooks/`, inventory `AO Orchestrator Localhost`; the sync template uses `AAP Credential`)
- workflow `AO Lab | Provision and register`: Create VPC, Create Keypair, three Create VM nodes, then wire, then register

`playbooks/register-rhel-nodes.yml` runs on `lab-inventory`. It removes the AWS RHUI client (these are hourly RHEL images), then applies `redhat.rhel_system_roles.rhc`. It does not upgrade packages. The role registers with the activation key, connects Insights, and sets tag `group` to a name unique to this deployment (`ao-cve-<cluster id>` from `CONTROLLER_HOST`, or `AO_INSIGHTS_GROUP` when set). Shared names `cve-lab` and `xfd48` are refused. The job output `lab_tag` is the value for the AO trigger. Remediation stays off. `rhc_insights.autoupdate` only refreshes the Insights client configuration. The controller project sync installs the collection from `collections/requirements.yml` at the repository root.

Blueprint `rhel9` would select the newest hourly AMI. The Create VM extra var `create_vm_aws_image_filter` is `RHEL-9.6.0_HVM-202506*` so the image still has 9.6 errata. An existing Name tag makes Create VM skip the launch, so terminate `cve-node1`, `cve-node2`, and `cve-node3` before creating them again. Do not run `dnf update` afterward. Do not set a subscription-manager release lock. Insights reports that lock as `rhsm_lock` and then scores no CVEs on these hosts.

`local/ansible-navigator.yml` runs without an execution environment. The supported AAP image on `registry.redhat.io` needs `podman login` first; this machine already has the `ansible.controller` collection. That collection's token call to `/api/controller/v2/tokens/` returns 404 on this gateway, so the local playbooks create a short-lived token at `/api/gateway/v1/tokens/` and delete it when the play finishes.

```bash
cd demo-aiops/aiops-orchestrator
set -a && source .env && set +a
cd local
ansible-navigator run ../playbooks/configure-aap.yml \
  --penv CONTROLLER_HOST --penv CONTROLLER_USERNAME --penv CONTROLLER_PASSWORD \
  --penv RHSM_ORG_ID --penv RHSM_ACTIVATION_KEY \
  -e ao_launch_workflow=true
```

`ao_launch_workflow` defaults to false, which only creates the objects. The same playbook can be re-run safely.

`playbooks/configure-ao.yml` then builds the Automation Orchestrator side over the AO REST API. `POST /api/v1/auth/login` takes the local admin account, so none of this needs the UI. The OpenAPI spec is at `<AO_URL>/api_docs/v1/openapi.json`.

```bash
cd local
ansible-navigator run ../playbooks/configure-ao.yml \
  --penv AO_URL --penv AO_USERNAME --penv AO_PASSWORD \
  --penv AO_MODEL_BASE_URL --penv AO_MODEL_NAME --penv AO_MODEL_ACCESS_TOKEN \
  --penv CONTROLLER_HOST --penv CONTROLLER_USERNAME --penv CONTROLLER_PASSWORD \
  --penv AAP_MCP_TOKEN
```

It creates credentials and global integrations `MaaS` (LLM provider, model from `AO_MODEL_NAME`), `AAP MCP` (`hosts_list`, `hosts_variable_data_retrieve`), `Lightspeed MCP` (the vulnerability, inventory, remediation, and advisor tools the workflow calls), and `AAP`, then validates all four and fails if any is unhealthy. It matches on name, so re-running changes nothing. MCP URLs are derived from the cluster in `CONTROLLER_HOST`; set `AAP_MCP_URL` or `LIGHTSPEED_MCP_URL` to override. `AAP_MCP_TOKEN` is a persistent AAP gateway token; the playbook creates one if the variable is empty, so put it in `.env` to keep re-runs on the same token.

`playbooks/configure-ao-workflow.yml` then imports `demo-cve-remediation/ao/rhel-cve-remediation.json`:

```bash
AO_DEMO_CVE=CVE-2026-31431 ansible-navigator run ../playbooks/configure-ao-workflow.yml \
  --penv AO_URL --penv AO_USERNAME --penv AO_PASSWORD --penv AO_MODEL_NAME \
  --penv CONTROLLER_HOST --penv AO_INSIGHTS_GROUP --penv AO_DEMO_CVE --penv AO_DEMO_HOST
```

The export carries no instance ids, so the play sets organization `Ansible Product Demos (APD)` and the AAP integration and credential on every job template node, the model, credential, tool selection, and MCP execution connections on both agent nodes, and the trigger defaults for `host`, `cve_id`, and `lab_tag`. It then validates, creates, and publishes; an import without a published version has no manual trigger. Re-running replaces the previous copy of the same name, so edits to the JSON do take effect.

`AO_DEMO_CVE` has to be a CVE that Lightspeed lists for the host with an errata — the triage prompt does not pick one when the field is empty. `AO_DEMO_HOST` defaults to `node1`, which is the dev host and so the auto-patch path; `node2` and `node3` are production and stop at the approval node.

Nothing is left to do by hand. `.cursor/skills/ao-cve-lab/ui.md` describes what the playbooks build, for checking their work in the UI.

The older local launchers still work for the cloud templates and inventory wiring:

```bash
ansible-navigator run ../playbooks/provision-rhel-nodes.yml \
  --penv CONTROLLER_HOST --penv CONTROLLER_USERNAME --penv CONTROLLER_PASSWORD
ansible-navigator run ../playbooks/wire-lab-inventory.yml \
  --penv CONTROLLER_HOST --penv CONTROLLER_USERNAME --penv CONTROLLER_PASSWORD
```

Skip VPC or keypair creation when they already exist: `-e ao_create_vpc=false -e ao_create_keypair=false`.

Scenario write-ups stay on the [catalog](https://ansible-tmm.github.io/aap-orchestrator-demos/). The lab prerequisites for the RHEL CVE scenario (MCP manifests, Gitea, Mattermost, and the older workstation playbooks) are in [cve-remediation-setup](cve-remediation-setup/).

## Local aap-demo

[RedHatOfficial/aap-demo](https://github.com/RedHatOfficial/aap-demo) deploys AAP on a local MicroShift (CRC) cluster and has an AO addon. This path has not been run from this repo. Upstream sets the CRC VM to 16 GB RAM by default (`CRC_MEMORY=16384`).

```bash
git clone https://github.com/RedHatOfficial/aap-demo.git
cd aap-demo && ./install.sh
aap-demo deploy
aap-demo enable ao
aap-demo status
```

`aap-demo enable ao` asks for an LLM provider (local Ollama, an external OpenAI-compatible endpoint, or none). Agentic scenarios need a provider. The addon wires AAP and the MCP server, and can import the TMM workflow exports. Addon details: [addons/ao/README.md](https://github.com/RedHatOfficial/aap-demo/blob/main/addons/ao/README.md).

Raise memory before `aap-demo create` if the default VM is tight:

```bash
CRC_MEMORY=24576 aap-demo create
```
