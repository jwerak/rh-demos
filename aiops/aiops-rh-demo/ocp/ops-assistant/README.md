# Ops Incident Assistant - OpenShift Deployment

This directory contains a Kustomize overlay that uses the upstream [agent-ops-assistant](https://github.com/jwerak/agent-ops-assistant/tree/main/k8s) repository as a base.

## Prerequisites

- OpenShift cluster access
- `oc` CLI tool installed
- Container image built and pushed to a registry
- OpenAI API key (or compatible endpoint credentials)
- MCP server for Ansible Automation Platform deployed

## Kustomize Structure

This overlay references the remote GitHub repository as a base:

```yaml
resources:
  - https://github.com/jwerak/agent-ops-assistant/k8s
```

This approach allows you to:
- Use the upstream configuration as a base
- Override specific values with patches
- Keep your local changes minimal and maintainable

## Quick Start

### 1. Deploy with Default Configuration

```bash
# Deploy using kustomize
oc apply -k ./ocp/ops-assistant

# Or using kubectl
kubectl apply -k ./ocp/ops-assistant
```

### 2. Verify Deployment

```bash
# Check pod status
oc get pods -l app=ops-incident-assistant -n aiops

# Check logs
oc logs -f deployment/ops-incident-assistant -n aiops

# Get route URL
oc get route ops-incident-assistant -n aiops
```

## Customization

To customize the deployment, you can add patches to the `kustomization.yaml` file. Here are some common examples:

### Change Namespace

Edit `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: my-custom-namespace

resources:
  - https://github.com/jwerak/agent-ops-assistant/k8s
```

### Patch ConfigMap Values

Create a file `patch-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ops-assistant-config
data:
  openai-base-url: "https://my-openai-endpoint.com/v1"
  mcp-server-url: "https://my-mcp-server.example.com/mcp"
  model-name: "gpt-4"
  webhook-path: "my-custom-webhook-path"
```

Then reference it in `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - https://github.com/jwerak/agent-ops-assistant/k8s

patches:
  - path: patch-configmap.yaml
```

### Update Secret

Create a file `patch-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ops-assistant-secrets
type: Opaque
stringData:
  openai-api-key: "your-actual-api-key"
```

Then reference it in `kustomization.yaml`:

```yaml
patches:
  - path: patch-secret.yaml
```

### Change Container Image

Create a file `patch-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ops-incident-assistant
spec:
  template:
    spec:
      containers:
      - name: ops-assistant
        image: quay.io/my-org/ops-incident-assistant:v1.0.0
```

### Scale Replicas

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ops-incident-assistant
spec:
  replicas: 3
```

### Adjust Resources

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ops-incident-assistant
spec:
  template:
    spec:
      containers:
      - name: ops-assistant
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
```

## Testing the Deployment

Once deployed, get the route URL and test:

```bash
# Get the route
ROUTE=$(oc get route ops-incident-assistant -n aiops -o jsonpath='{.spec.host}')

# Test health endpoint
curl https://$ROUTE/health

# Send a test question
curl -X POST https://$ROUTE/webhook/7d1a79c6-2189-47d5-92c6-dfbac5b1fa59 \
  -H "Content-Type: application/json" \
  -d '{"question": "What job templates are available?"}'
```

## Viewing Built Configuration

To see the final rendered Kubernetes manifests:

```bash
kubectl kustomize ./ocp/ops-assistant
```

Or with oc:

```bash
oc kustomize ./ocp/ops-assistant
```

## Clean Up

To remove the deployment:

```bash
oc delete -k ./ocp/ops-assistant
```

## Benefits of This Approach

1. **Minimal local files**: Only maintain overrides, not entire configurations
2. **Upstream updates**: Easy to pull updates from the upstream repository
3. **Clear customizations**: Local changes are explicit and easy to review
4. **Version control**: Can pin to specific Git commits/tags if needed

## Pinning to a Specific Version

To use a specific version of the upstream configuration:

```yaml
resources:
  - https://github.com/jwerak/agent-ops-assistant/k8s?ref=v1.0.0
```

Or a specific commit:

```yaml
resources:
  - https://github.com/jwerak/agent-ops-assistant/k8s?ref=abc123
```

## Troubleshooting

### Remote Repository Access Issues

If you encounter issues accessing the remote repository, you can:

1. Clone the repository locally and reference it:
   ```yaml
   resources:
     - ../../path/to/agent-ops-assistant/k8s
   ```

2. Or fork the repository and use your fork:
   ```yaml
   resources:
     - https://github.com/your-org/agent-ops-assistant/k8s
   ```

### Configuration Not Applied

Make sure to restart the deployment after updating ConfigMaps or Secrets:

```bash
oc rollout restart deployment/ops-incident-assistant -n aiops
```

## Next Steps

- Create patches for your environment-specific configuration
- Set up CI/CD to automatically apply kustomize changes
- Add additional overlays for different environments (dev, staging, prod)
