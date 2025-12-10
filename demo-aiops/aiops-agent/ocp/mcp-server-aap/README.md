# MCP Server for Ansible Automation Platform - OpenShift Deployment

This directory contains a Kustomize overlay that uses the upstream [mcp-server-aap](https://github.com/jwerak/mcp-server-aap/tree/main/k8s) repository as a base.

## Prerequisites

- OpenShift cluster access
- `oc` CLI tool installed
- Ansible Automation Platform (AAP) instance running and accessible
- AAP credentials (username and token)

## Kustomize Structure

This overlay references the remote GitHub repository as a base:

```yaml
resources:
  - https://github.com/jwerak/mcp-server-aap/k8s/base
```

This approach allows you to:
- Use the upstream configuration as a base
- Override specific values with patches
- Keep your local changes minimal and maintainable

## Quick Start

### 1. Deploy with Default Configuration

```bash
# Deploy using kustomize
oc apply -k ./ocp/mcp-server-aap

# Or using kubectl
kubectl apply -k ./ocp/mcp-server-aap
```

### 2. Verify Deployment

```bash
# Check pod status
oc get pods -l app=mcp-server-aap -n mcp-server-aap

# Check logs
oc logs -f deployment/mcp-server-aap -n mcp-server-aap

# Get route URL
oc get route mcp-server-aap -n mcp-server-aap
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
  - https://github.com/jwerak/mcp-server-aap/k8s/base
```

### Patch ConfigMap for AAP Connection

Create a file `patch-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mcp-server-aap-config
data:
  aap-url: "https://my-aap-instance.example.com"
  aap-verify-ssl: "true"
```

Then reference it in `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - https://github.com/jwerak/mcp-server-aap/k8s/base

patches:
  - path: patch-configmap.yaml
```

### Update AAP Credentials

Create a file `secret.yaml`:

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

Then add it as a resource in `kustomization.yaml` (the base has the secret commented out):

```yaml
resources:
  - https://github.com/jwerak/mcp-server-aap/k8s/base
  - secret.yaml
```

### Change Container Image

Create a file `patch-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-server-aap
spec:
  template:
    spec:
      containers:
      - name: mcp-server
        image: quay.io/my-org/mcp-server-aap:v1.0.0
```

### Adjust Resources

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-server-aap
spec:
  template:
    spec:
      containers:
      - name: mcp-server
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "1Gi"
            cpu: "500m"
```

## Testing the Deployment

Once deployed, get the route URL and test the MCP server:

```bash
# Get the route
ROUTE=$(oc get route mcp-server-aap -n mcp-server-aap -o jsonpath='{.spec.host}')

# Test the MCP endpoint
curl https://$ROUTE/mcp

# Test health endpoint (if available)
curl https://$ROUTE/health
```

## Pinning to a Specific Version

To use a specific version of the upstream configuration:

```yaml
resources:
  - https://github.com/jwerak/mcp-server-aap/k8s/base?ref=v1.0.0
```

Or a specific commit:

```yaml
resources:
  - https://github.com/jwerak/mcp-server-aap/k8s/base?ref=abc123
```

## Troubleshooting

### MCP Server Not Connecting to AAP

Check the logs for connection errors:

```bash
oc logs -f deployment/mcp-server-aap -n mcp-server-aap
```

Common issues:
- Incorrect AAP URL in ConfigMap
- Invalid credentials in Secret
- Network connectivity issues
- SSL certificate verification failures

### Configuration Not Applied

Make sure to restart the deployment after updating ConfigMaps or Secrets:

```bash
oc rollout restart deployment/mcp-server-aap -n mcp-server-aap
```

### Testing AAP Connectivity

You can exec into the pod to test connectivity:

```bash
oc exec -it deployment/mcp-server-aap -n mcp-server-aap -- /bin/sh
# Then test curl to AAP endpoint
curl -v https://your-aap-instance.com
```

## Next Steps

- Create patches for your AAP instance configuration
- Configure TLS certificates if using custom CA
- Set up monitoring and alerting
- Add additional overlays for different environments (dev, staging, prod)
