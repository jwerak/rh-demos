# Ops Incident Assistant - OpenShift Deployment

Kubernetes/OpenShift deployment manifests for the Ops Incident Assistant.

## Prerequisites

- OpenShift cluster access
- `oc` CLI tool installed
- Container image built and pushed to a registry
- OpenAI API key (or compatible endpoint credentials)
- MCP server for Ansible Automation Platform deployed

## Quick Start

### 1. Build and Push Container Image

```bash
# Build the image
cd /home/jveverka/git/rh-demos/aiops/aiops-rh-demo
podman build -t quay.io/your-org/ops-incident-assistant:latest .

# Push to registry
podman push quay.io/your-org/ops-incident-assistant:latest
```

### 2. Create Namespace

```bash
oc new-project aiops
```

### 3. Configure Secrets and ConfigMap

Edit `secret.yaml` to add your OpenAI API key:

```bash
oc create secret generic ops-assistant-secrets \
  --from-literal=openai-api-key='your-actual-api-key'
```

Edit `configmap.yaml` to configure your endpoints:

```yaml
data:
  openai-base-url: "https://your-openai-endpoint.com/v1"
  mcp-server-url: "https://mcp-server-aap.apps.your-cluster.com/mcp"
  model-name: "DeepSeek-R1-Distill-Qwen-14B-W4A16"
  webhook-path: "7d1a79c6-2189-47d5-92c6-dfbac5b1fa59"
```

### 4. Deploy Using Kustomize

```bash
# Deploy all resources
oc apply -k .

# Or deploy individually
oc apply -f configmap.yaml
oc apply -f secret.yaml
oc apply -f deployment.yaml
oc apply -f service.yaml
oc apply -f route.yaml
```

### 5. Verify Deployment

```bash
# Check pod status
oc get pods -l app=ops-incident-assistant

# Check logs
oc logs -f deployment/ops-incident-assistant

# Get route URL
oc get route ops-incident-assistant
```

## Testing the Deployment

Once deployed, get the route URL and test:

```bash
# Get the route
ROUTE=$(oc get route ops-incident-assistant -o jsonpath='{.spec.host}')

# Test health endpoint
curl https://$ROUTE/health

# Send a test question
curl -X POST https://$ROUTE/webhook/7d1a79c6-2189-47d5-92c6-dfbac5b1fa59 \
  -H "Content-Type: application/json" \
  -d '{"question": "What job templates are available?"}'
```

## Configuration

### Environment Variables

The deployment uses the following environment variables:

| Variable          | Source    | Description                            |
| ----------------- | --------- | -------------------------------------- |
| `OPENAI_API_KEY`  | Secret    | API key for OpenAI-compatible endpoint |
| `OPENAI_BASE_URL` | ConfigMap | Base URL for OpenAI-compatible API     |
| `MCP_SERVER_URL`  | ConfigMap | URL of the MCP server                  |
| `MODEL_NAME`      | ConfigMap | Name of the LLM model to use           |
| `WEBHOOK_PATH`    | ConfigMap | Webhook path identifier                |

### Updating Configuration

To update configuration without redeploying:

```bash
# Update ConfigMap
oc edit configmap ops-assistant-config

# Restart deployment to pick up changes
oc rollout restart deployment/ops-incident-assistant
```

### Updating Secrets

```bash
# Update secret
oc create secret generic ops-assistant-secrets \
  --from-literal=openai-api-key='new-api-key' \
  --dry-run=client -o yaml | oc apply -f -

# Restart deployment
oc rollout restart deployment/ops-incident-assistant
```

## Resource Requirements

Default resource configuration:

- **Requests**: 512Mi memory, 250m CPU
- **Limits**: 2Gi memory, 1000m CPU

Adjust in `deployment.yaml` based on your workload:

```yaml
resources:
  requests:
    memory: "512Mi"
    cpu: "250m"
  limits:
    memory: "2Gi"
    cpu: "1000m"
```

## Scaling

The deployment defaults to 1 replica. To scale:

```bash
# Scale up
oc scale deployment ops-incident-assistant --replicas=3

# Autoscaling
oc autoscale deployment ops-incident-assistant \
  --min=1 --max=5 --cpu-percent=80
```

## Monitoring

### View Logs

```bash
# Stream logs
oc logs -f deployment/ops-incident-assistant

# View recent logs
oc logs deployment/ops-incident-assistant --tail=100
```

### Health Checks

The deployment includes liveness and readiness probes:

- **Liveness**: `/health` endpoint checked every 10s
- **Readiness**: `/health` endpoint checked every 5s

### Metrics

To expose Prometheus metrics, add a ServiceMonitor:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ops-incident-assistant
spec:
  selector:
    matchLabels:
      app: ops-incident-assistant
  endpoints:
  - port: http
    path: /metrics
    interval: 30s
```

## Troubleshooting

### Pod Not Starting

```bash
# Check pod events
oc describe pod -l app=ops-incident-assistant

# Check logs
oc logs -l app=ops-incident-assistant
```

### Common Issues

1. **Image Pull Errors**
   - Verify image exists in registry
   - Check image pull secrets if using private registry

2. **Configuration Errors**
   - Verify ConfigMap and Secret values
   - Check environment variable names

3. **MCP Connection Failed**
   - Verify MCP server URL is accessible
   - Check network policies
   - Verify MCP server is running

4. **OpenAI API Errors**
   - Verify API key is correct
   - Check base URL configuration
   - Verify model name is available

## Security Considerations

1. **Secrets Management**
   - Use sealed secrets or external secret operators
   - Rotate API keys regularly
   - Never commit secrets to git

2. **Network Policies**
   - Restrict ingress to necessary sources
   - Limit egress to OpenAI and MCP endpoints

3. **RBAC**
   - Create service account with minimal permissions
   - Use pod security policies

## Clean Up

To remove the deployment:

```bash
# Delete all resources
oc delete -k .

# Or delete individually
oc delete deployment ops-incident-assistant
oc delete service ops-incident-assistant
oc delete route ops-incident-assistant
oc delete configmap ops-assistant-config
oc delete secret ops-assistant-secrets
```

## Integration with n8n

If you want to integrate with the existing n8n deployment, you can:

1. Update the n8n workflow to point to this service
2. Use the internal service URL: `http://ops-incident-assistant.aiops.svc.cluster.local:5678`
3. Update the webhook path in both services to match

## Next Steps

- Set up monitoring with Prometheus/Grafana
- Configure alerting for failures
- Implement request authentication
- Add rate limiting
- Set up CI/CD pipeline for automatic deployments


