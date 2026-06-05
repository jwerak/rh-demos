# CLAUDE.md

AIOps demo: agent-based incident response using AAP (Ansible Automation Platform) and an AI ops assistant deployed to OpenShift.

## Sub-projects

- **aiops-aap/**: Ansible playbooks to configure AAP workflows for the AIOps demo. Requires a provisioned AAP instance from demo catalog.
- **aiops-agent/**: Deploys two components to OpenShift via Kustomize overlays referencing upstream GitHub repos:
  - `ocp/mcp-server-aap/` - MCP server bridging AAP to the agent (namespace: `mcp-server-aap`, base: `github.com/jwerak/mcp-server-aap`)
  - `ocp/ops-assistant/` - AI ops incident assistant (namespace: `aiops`, base: `github.com/jwerak/agent-ops-assistant`)

## Key Commands

### AAP Setup
```bash
cd aiops-aap
cp .env.sample .env  # fill in CONTROLLER_USERNAME, CONTROLLER_PASSWORD, CONTROLLER_HOST
source .env
ansible-navigator run playbooks/aiops-workflows.yml --penv CONTROLLER_USERNAME --penv CONTROLLER_PASSWORD --penv CONTROLLER_HOST
```

### Deploy MCP Server
```bash
cd aiops-agent
# Edit ocp/mcp-server-aap/patch-configmap.yaml and secret.yaml with AAP credentials
oc apply -k ocp/mcp-server-aap
oc get route mcp-server-aap -n mcp-server-aap -o jsonpath='{.spec.host}'
```

### Deploy Ops Assistant
```bash
cd aiops-agent
# Edit ocp/ops-assistant/patch-configmap.yaml and patch-secret.yaml
oc new-project aiops
oc apply -k ocp/ops-assistant/
oc get route -n aiops ops-incident-assistant
```

### Test
```bash
ROUTE=$(oc get route -n aiops ops-incident-assistant -o jsonpath='{.spec.host}')
curl -X POST https://${ROUTE}/webhook/7d1a79c6-2189-47d5-92c6-dfbac5b1fa59 \
  -H "Content-Type: application/json" \
  -d '{"question": "What job templates are available?"}' | sed 's/\\n/\n/g'
```

### Logs
```bash
oc logs -l app=ops-incident-assistant -n aiops --tail=100 -f
```

## Key Tools

- `oc` (OpenShift CLI) - deploy and manage resources
- `ansible-navigator` - run AAP setup playbooks
- `kustomize` (or `oc apply -k`) - build and apply overlays

## Credentials

Sensitive files (`patch-secret.yaml`, `secret.yaml`, `.env`) are gitignored. Copy from `*-example.yaml` or `.env.sample` templates.
