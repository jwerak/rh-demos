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


### Deploy AAP MCP

MCP is forked from [mancubus77](https://github.com/mancubus77/mcp-server-aap).

To deploy to OCP, follow [this repo instructions](https://github.com/jwerak/mcp-server-aap/tree/main/k8s).

## Python/LangGraph Implementation

As an alternative to n8n, we've created a Python implementation using LangGraph that provides the same functionality with additional benefits for production environments.

### Features

- 🐍 **Pure Python**: Built with LangGraph, FastAPI, and LangChain
- 🔧 **Full Control**: Complete customization of agent behavior
- 🧪 **Testable**: Unit and integration tests included
- 📦 **Containerized**: Docker and OpenShift ready
- 📊 **Observable**: Better logging and monitoring capabilities
- 🚀 **Scalable**: Designed for production workloads
- 🔄 **Resilient**: Automatic retry with exponential backoff for transient failures

### Quick Start (Local)

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

### Deploy to OpenShift

```bash
oc new-project aiops
oc apply -k ocp/ops-assistant/

# Get route
oc get route ops-incident-assistant
```

### Test the Python Implementation

```bash
ROUTE=$(oc get route ops-incident-assistant -o jsonpath='{.spec.host}')

curl -X POST https://${ROUTE}/webhook/7d1a79c6-2189-47d5-92c6-dfbac5b1fa59 \
  -H "Content-Type: application/json" \
  -d '{"question": "What job templates are available?"}'
```

### Documentation

- **[IMPLEMENTATION_GUIDE.md](./ops-assistant/IMPLEMENTATION_GUIDE.md)** - Complete implementation guide
- **[ocp/ops-assistant/README.md](./ocp/ops-assistant/README.md)** - OpenShift deployment guide

### Choosing Between n8n and Python

**Use n8n if:**
- Your team prefers visual workflow design
- You need rapid prototyping
- No coding experience required

**Use Python/LangGraph if:**
- You need production-grade reliability
- Testing and CI/CD are important
- You want full customization
- Your team has Python experience
