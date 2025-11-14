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

## Deploy Agentic AIOps

### Deploy AAP Environment with Demo

To deploy to OCP, follow [this repo instructions](https://github.com/jwerak/ansible_devops_demo/tree/main/demo_aiops).

tl;dr: When OCP is ready, execute:

```bash
ansible-playbook -i localhost-only  -e @./demo_aiops/.env ./playbooks/_deploy_demo_on_ocp.yml
```

### Deploy AAP MCP

Update patches for configmap (`./ocp/mcp-server-aap/patch-configmap.yaml`) and secret `./ocp/mcp-server-aap/secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mcp-server-aap-secret
type: Opaque
stringData:
  aap-username: "your-aap-username"
  aap-token: "your-aap-token"
```

```bash
# Deploy using kustomize
oc apply -k ./ocp/mcp-server-aap
```

Get Route mcp-server route:

```bash
ROUTE=$(oc get route mcp-server-aap -n mcp-server-aap -o jsonpath='{.spec.host}')&& echo ${ROUTE}
```

More deployment info is in [this folder](./ocp/mcp-server-aap/).

### Deploy Ops Assistant Agent

#### Quick Start (Local)

```bash
# Install dependencies
pip install -r requirements.txt

# Configure environment (copy and edit)
cp env.example .env
# Edit .env with your API keys and configuration

# Run locally
python ops_incident_assistant.py

# Test
python test_client.py
```

#### Deploy to OpenShift

```bash
oc new-project aiops
oc apply -k ocp/ops-assistant/

# Get route
oc get route -n aiops ops-incident-assistant
```

### Test the Python Implementation

```bash
ROUTE=$(oc get route -n aiops ops-incident-assistant -o jsonpath='{.spec.host}')

curl -X POST https://${ROUTE}/webhook/7d1a79c6-2189-47d5-92c6-dfbac5b1fa59 \
  -H "Content-Type: application/json" \
  -d '{"question": "What job templates are available?"}'
```
