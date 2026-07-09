#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="${SCRIPT_DIR}/.."

echo "=== VM Self-Service Portal Deployment ==="
echo ""

# --- Validate required environment variables ---
: "${BASE_DOMAIN:?ERROR: BASE_DOMAIN must be set. Run: source .env}"
: "${GITLAB_ADMIN_PASSWORD:?ERROR: GITLAB_ADMIN_PASSWORD must be set}"
: "${GITLAB_TOKEN:?ERROR: GITLAB_TOKEN must be set}"
: "${BACKEND_SECRET:?ERROR: BACKEND_SECRET must be set}"
: "${GITHUB_REPO:?ERROR: GITHUB_REPO must be set}"
: "${GIT_REVISION:?ERROR: GIT_REVISION must be set}"
: "${KEYCLOAK_ADMIN_PASSWORD:?ERROR: KEYCLOAK_ADMIN_PASSWORD must be set}"
: "${KEYCLOAK_CLIENT_SECRET:?ERROR: KEYCLOAK_CLIENT_SECRET must be set}"

DEMO_PASSWORD="${DEMO_PASSWORD:-$(openssl rand -base64 12)}"
ARGOCD_PASSWORD=""

echo "Base Domain:    ${BASE_DOMAIN}"
echo "GitHub Repo:    ${GITHUB_REPO}"
echo "Git Revision:   ${GIT_REVISION}"
echo ""

apply_templated() {
  local file="$1"
  sed \
    -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" \
    -e "s|__GITHUB_REPO__|${GITHUB_REPO}|g" \
    -e "s|__GIT_REVISION__|${GIT_REVISION}|g" \
    -e "s|__BACKEND_SECRET__|${BACKEND_SECRET}|g" \
    -e "s|__GITLAB_ADMIN_PASSWORD__|${GITLAB_ADMIN_PASSWORD}|g" \
    -e "s|__GITLAB_TOKEN__|${GITLAB_TOKEN}|g" \
    -e "s|__DEMO_PASSWORD__|${DEMO_PASSWORD}|g" \
    -e "s|__KEYCLOAK_ADMIN_PASSWORD__|${KEYCLOAK_ADMIN_PASSWORD}|g" \
    -e "s|__KEYCLOAK_CLIENT_SECRET__|${KEYCLOAK_CLIENT_SECRET}|g" \
    -e "s|__ARGOCD_PASSWORD__|${ARGOCD_PASSWORD}|g" \
    "$file" | oc apply -f -
}

# Phase 0: Verify prerequisites
echo "--- Phase 0: Checking prerequisites ---"
if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged into OpenShift. Run: oc login ..."
  exit 1
fi
echo "Logged in as: $(oc whoami)"
echo ""

# Phase 1: Install OpenShift GitOps (ArgoCD)
echo "--- Phase 1: Installing OpenShift GitOps Operator + RBAC ---"
oc apply -k "${BASE_DIR}/bootstrap/"

echo "Waiting for OpenShift GitOps Operator CSV..."
for i in $(seq 1 60); do
  if oc get csv -n openshift-operators -l operators.coreos.com/openshift-gitops-operator.openshift-operators -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Succeeded; then
    echo "OpenShift GitOps Operator is ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: OpenShift GitOps Operator not ready after 5 minutes. Continuing..."
  fi
  sleep 5
done

echo "Waiting for ArgoCD server..."
oc wait deployment/openshift-gitops-server -n openshift-gitops --for=condition=Available --timeout=300s 2>/dev/null || true

echo "Configuring ArgoCD RBAC (readonly for all authenticated users)..."
oc patch argocd openshift-gitops -n openshift-gitops --type merge \
  -p '{"spec":{"rbac":{"defaultPolicy":"role:readonly","policy":"g, system:cluster-admins, role:admin\ng, cluster-admins, role:admin\n","scopes":"[groups]"}}}' 2>/dev/null || true

echo "Enabling ApplicationSet controller..."
oc patch argocd openshift-gitops -n openshift-gitops --type merge \
  -p '{"spec":{"applicationSet":{"resources":{"limits":{"cpu":"1","memory":"1Gi"},"requests":{"cpu":"250m","memory":"256Mi"}}}}}' 2>/dev/null || true

echo "Waiting for ApplicationSet controller..."
for i in $(seq 1 30); do
  if oc get pods -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-applicationset-controller 2>/dev/null | grep -q Running; then
    echo "ApplicationSet controller is ready."
    break
  fi
  sleep 5
done
echo ""

# Phase 2: Deploy RHDH Operator via ArgoCD
echo "--- Phase 2: Deploying RHDH Operator ---"
apply_templated "${BASE_DIR}/argocd-apps/phase1-operators.yaml"

echo "Waiting for RHDH Operator CSV..."
for i in $(seq 1 60); do
  if oc get csv -n rhdh-operator -l operators.coreos.com/rhdh.rhdh-operator -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Succeeded; then
    echo "RHDH Operator is ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: RHDH Operator not ready after 5 minutes. Continuing..."
  fi
  sleep 5
done
echo ""

# Phase 3: Deploy GitLab CE
echo "--- Phase 3: Deploying GitLab CE ---"
for f in namespace scc pvc deployment service route; do
  apply_templated "${BASE_DIR}/base/gitlab/${f}.yaml"
done

echo "Waiting for GitLab deployment (this takes 3-5 minutes)..."
oc wait deployment/gitlab -n gitlab --for=condition=Available --timeout=600s 2>/dev/null || true

echo "Waiting for GitLab readiness..."
for i in $(seq 1 60); do
  if curl -ksS -o /dev/null -w "%{http_code}" "https://gitlab.${BASE_DOMAIN}/-/readiness" 2>/dev/null | grep -q 200; then
    echo "GitLab is ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: GitLab not responding after 10 minutes. Continuing..."
  fi
  sleep 10
done
echo ""

# Phase 3b: Deploy Keycloak
echo "--- Phase 3b: Deploying Keycloak ---"
for f in namespace realm-cm deployment service route; do
  apply_templated "${BASE_DIR}/base/keycloak/${f}.yaml"
done

echo "Waiting for Keycloak readiness..."
for i in $(seq 1 60); do
  if curl -ksS -o /dev/null -w "%{http_code}" "https://keycloak.${BASE_DOMAIN}/realms/master" 2>/dev/null | grep -q 200; then
    echo "Keycloak is ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: Keycloak not responding after 5 minutes. Continuing..."
  fi
  sleep 5
done

"${SCRIPT_DIR}/configure-keycloak.sh"
echo ""

# Extract ArgoCD admin password (auto-generated by GitOps operator)
ARGOCD_PASSWORD=$(oc extract secret/openshift-gitops-cluster -n openshift-gitops --to=- --keys=admin.password 2>/dev/null)
echo "ArgoCD admin password extracted."
echo ""

# Phase 4: Deploy RHDH
echo "--- Phase 4: Deploying RHDH ---"
apply_templated "${BASE_DIR}/base/rhdh/namespace.yaml"
apply_templated "${BASE_DIR}/base/rhdh/secrets.yaml"
apply_templated "${BASE_DIR}/base/rhdh/app-config-cm.yaml"
apply_templated "${BASE_DIR}/base/rhdh/dynamic-plugins-cm.yaml"
apply_templated "${BASE_DIR}/base/rhdh/rbac-policies-cm.yaml"
apply_templated "${BASE_DIR}/base/rhdh/backstage-cr.yaml"

echo "Waiting for RHDH deployment..."
for i in $(seq 1 60); do
  if oc get backstage rhdh -n rhdh -o jsonpath='{.status.conditions[?(@.type=="Deployed")].status}' 2>/dev/null | grep -q True; then
    echo "RHDH is deployed."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: RHDH not ready after 5 minutes. Continuing..."
  fi
  sleep 5
done
echo ""

# Phase 5: Seed GitLab with templates
echo "--- Phase 5: Seeding GitLab ---"
"${SCRIPT_DIR}/seed-gitlab.sh"
echo ""

# Phase 6: Deploy demo environments + VM ApplicationSet
echo "--- Phase 6: Deploying demo environments ---"
apply_templated "${BASE_DIR}/argocd-apps/phase3-demo-env.yaml"
echo ""

echo "--- Phase 6b: Deploying VM ApplicationSet (GitLab SCM Provider) ---"
apply_templated "${BASE_DIR}/argocd-apps/vm-instances-appset.yaml"
echo "  ApplicationSet 'vm-instances' watches GitLab group for new VM repos."
echo ""

# Phase 7: Gatekeeper OPA Policies
echo "--- Phase 7: Installing Gatekeeper OPA ---"
oc apply -k "${BASE_DIR}/base/gatekeeper/operator/"

echo "Waiting for Gatekeeper Operator CSV..."
for i in $(seq 1 60); do
  if oc get csv -n openshift-gatekeeper-system -l operators.coreos.com/gatekeeper-operator-product.openshift-gatekeeper-system -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Succeeded; then
    echo "Gatekeeper Operator is ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: Gatekeeper Operator not ready after 5 minutes. Continuing..."
  fi
  sleep 5
done

echo "Creating Gatekeeper instance..."
oc apply -f "${BASE_DIR}/base/gatekeeper/instance/gatekeeper.yaml"

echo "Waiting for Gatekeeper controller..."
for i in $(seq 1 60); do
  if oc get pods -n openshift-gatekeeper-system -l control-plane=controller-manager 2>/dev/null | grep -q Running; then
    echo "Gatekeeper controller is running."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: Gatekeeper controller not ready after 5 minutes. Continuing..."
  fi
  sleep 5
done

echo "Waiting for Gatekeeper webhook..."
for i in $(seq 1 30); do
  if oc get pods -n openshift-gatekeeper-system -l control-plane=audit-controller 2>/dev/null | grep -q Running; then
    echo "Gatekeeper audit controller is running."
    break
  fi
  sleep 5
done

echo "Applying ConstraintTemplates..."
for f in vm-naming-template vm-resource-limits-template vm-required-labels-template; do
  oc apply -f "${BASE_DIR}/base/gatekeeper/policies/${f}.yaml"
done

echo "Waiting for ConstraintTemplates to be established..."
for i in $(seq 1 30); do
  READY=$(oc get constrainttemplates -o jsonpath='{range .items[*]}{.status.created}{"\n"}{end}' 2>/dev/null | grep -c true || echo 0)
  if [ "${READY}" -ge 3 ]; then
    echo "All 3 ConstraintTemplates are established."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "WARNING: Not all ConstraintTemplates ready after 150s. Continuing..."
  fi
  sleep 5
done

echo "Applying Constraints..."
for f in vm-naming vm-resource-limits vm-required-labels; do
  oc apply -f "${BASE_DIR}/base/gatekeeper/policies/${f}.yaml"
done
echo ""

# Phase 8: Serverless Operators (for SonataFlow/Orchestrator)
echo "--- Phase 8: Installing Serverless Operators ---"

echo "Creating OpenShift Serverless namespace..."
oc apply -f "${BASE_DIR}/base/serverless/namespace-serverless.yaml"
oc apply -f "${BASE_DIR}/base/serverless/operatorgroup-serverless.yaml"
oc apply -f "${BASE_DIR}/base/serverless/subscription-serverless.yaml"

echo "Creating Serverless Logic namespace..."
oc apply -f "${BASE_DIR}/base/serverless/namespace-logic.yaml"
oc apply -f "${BASE_DIR}/base/serverless/operatorgroup-logic.yaml"
oc apply -f "${BASE_DIR}/base/serverless/subscription-logic.yaml"

echo "Waiting for Serverless Operator CSV..."
for i in $(seq 1 90); do
  if oc get csv -n openshift-serverless 2>/dev/null | grep -q serverless-operator.*Succeeded; then
    echo "Serverless Operator is ready."
    break
  fi
  if [ "$i" -eq 90 ]; then
    echo "WARNING: Serverless Operator not ready after 7.5 minutes. Continuing..."
  fi
  sleep 5
done

echo "Waiting for Serverless Logic Operator CSV..."
for i in $(seq 1 90); do
  if oc get csv -n openshift-serverless-logic 2>/dev/null | grep -q logic-operator.*Succeeded; then
    echo "Serverless Logic Operator is ready."
    break
  fi
  if [ "$i" -eq 90 ]; then
    echo "WARNING: Serverless Logic Operator not ready after 7.5 minutes. Continuing..."
  fi
  sleep 5
done
echo ""

# Phase 9: Orchestrator Platform
echo "--- Phase 9: Deploying Orchestrator Platform ---"

echo "Extracting RHDH PostgreSQL credentials..."
PG_USER=$(oc get secret backstage-psql-secret-rhdh -n rhdh -o jsonpath='{.data.POSTGRES_USER}' 2>/dev/null | base64 -d)
PG_PASS=$(oc get secret backstage-psql-secret-rhdh -n rhdh -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d)

if [ -z "$PG_USER" ] || [ -z "$PG_PASS" ]; then
  echo "WARNING: Could not extract RHDH PostgreSQL credentials. Orchestrator persistence may fail."
  PG_USER="postgres"
  PG_PASS="postgres"
fi

echo "Creating orchestrator database and schemas..."
PG_POD="backstage-psql-rhdh-0"
if oc get pod "$PG_POD" -n rhdh &>/dev/null; then
  oc exec "$PG_POD" -n rhdh -- psql -U "$PG_USER" -c "CREATE DATABASE backstage_plugin_orchestrator;" 2>/dev/null || echo "  Database may already exist."
  oc exec "$PG_POD" -n rhdh -- psql -U "$PG_USER" -d backstage_plugin_orchestrator -c "
    CREATE SCHEMA IF NOT EXISTS \"request-vm-approval\";
    SET search_path TO \"request-vm-approval\";
    CREATE TABLE IF NOT EXISTS process_instances (
      id varchar(36) NOT NULL PRIMARY KEY,
      payload bytea,
      process_id varchar(255),
      version bigint,
      process_version varchar(255),
      created_by varchar(255)
    );
    CREATE TABLE IF NOT EXISTS correlation_instances (
      id varchar(36) NOT NULL PRIMARY KEY,
      encoded_correlation_id varchar(36) NOT NULL UNIQUE,
      correlated_id varchar(36) NOT NULL,
      correlation bytea NOT NULL
    );
  " 2>/dev/null || echo "  Schema/tables may already exist."
  echo "  Orchestrator database, schema, and tables created."
else
  echo "  WARNING: PostgreSQL pod not found. Database must be created manually."
fi

echo "Creating SonataFlow DB credentials secret..."
oc create secret generic sonataflow-db-credentials -n rhdh \
  --from-literal=POSTGRES_USER="$PG_USER" \
  --from-literal=POSTGRES_PASSWORD="$PG_PASS" \
  --dry-run=client -o yaml | oc apply -f -

echo "Deploying SonataFlowPlatform..."
oc apply -f "${BASE_DIR}/base/orchestrator/sonataflow-platform.yaml"

echo "Waiting for Data Index service..."
for i in $(seq 1 60); do
  if oc get svc sonataflow-platform-data-index-service -n rhdh &>/dev/null; then
    echo "Data Index service is ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: Data Index service not found after 5 minutes. Continuing..."
  fi
  sleep 5
done

echo "Resolving GitLab IDs for workflow..."
OCP_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "apps.cluster.local")
GITLAB_APPROVALS_PROJECT_ID=""
VM_INSTANCES_GROUP_ID=""

for i in $(seq 1 10); do
  GITLAB_APPROVALS_PROJECT_ID=$(curl -ksS -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "https://gitlab.${BASE_DOMAIN}/api/v4/projects/demo%2Fvm-approvals" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
  VM_INSTANCES_GROUP_ID=$(curl -ksS -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "https://gitlab.${BASE_DOMAIN}/api/v4/groups/vm-instances" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
  if [ -n "$GITLAB_APPROVALS_PROJECT_ID" ] && [ -n "$VM_INSTANCES_GROUP_ID" ]; then
    break
  fi
  sleep 3
done
echo "  vm-approvals project ID: ${GITLAB_APPROVALS_PROJECT_ID:-NOT_FOUND}"
echo "  vm-instances group ID: ${VM_INSTANCES_GROUP_ID:-NOT_FOUND}"

echo "Creating workflow credentials secret..."
oc create secret generic workflow-credentials -n rhdh \
  --from-literal=GITLAB_TOKEN="${GITLAB_TOKEN}" \
  --from-literal=GITLAB_URL="http://gitlab.gitlab.svc.cluster.local" \
  --from-literal=GITLAB_PROJECT_ID="${GITLAB_APPROVALS_PROJECT_ID:-1}" \
  --from-literal=VM_INSTANCES_GROUP_ID="${VM_INSTANCES_GROUP_ID:-1}" \
  --from-literal=cluster_console_url="https://console-openshift-console.${OCP_DOMAIN}" \
  --from-literal=vm_check_running_max_retries="30" \
  --from-literal=QUARKUS_REST_CLIENT_GITLAB_OPENAPI_YAML_URL="http://gitlab.gitlab.svc.cluster.local/api/v4" \
  --from-literal=QUARKUS_TLS_TRUST_ALL="true" \
  --from-literal=NOTIFICATIONS_URL="http://backstage-rhdh.rhdh.svc.cluster.local" \
  --from-literal=BACKEND_SECRET="${BACKEND_SECRET}" \
  --from-literal=BASE_DOMAIN="${BASE_DOMAIN}" \
  --dry-run=client -o yaml | oc apply -f -

echo "Building workflow image on cluster..."
oc new-build --binary --strategy=docker --name=wf-request-vm-build -n rhdh \
  --to=wf-request-vm:latest 2>/dev/null || true
oc start-build wf-request-vm-build -n rhdh \
  --from-dir="${BASE_DIR}/workflows/request-vm-approval" --wait 2>/dev/null
echo "  Workflow image built and pushed."

echo "Creating workflow ConfigMaps..."
oc create configmap request-vm-approval-schemas -n rhdh \
  --from-file="${BASE_DIR}/workflows/request-vm-approval/schemas/" \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap request-vm-approval-specs -n rhdh \
  --from-file="${BASE_DIR}/workflows/request-vm-approval/specs/" \
  --dry-run=client -o yaml | oc apply -f -

echo "Deploying SonataFlow workflow CR..."
oc apply -f "${BASE_DIR}/base/orchestrator/sonataflow-request-vm.yaml"

echo "Waiting for workflow pod..."
for i in $(seq 1 60); do
  if oc get pods -n rhdh --no-headers -l sonataflow.org/workflow-app=request-vm-approval 2>/dev/null | grep -q "1/1.*Running"; then
    echo "Workflow pod is running."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: Workflow pod not ready after 5 minutes."
  fi
  sleep 5
done

echo "Waiting for RHDH with Orchestrator plugins..."
for i in $(seq 1 90); do
  READY=$(oc get pods -n rhdh -l app.kubernetes.io/name=backstage -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
  if [ "$READY" = "true" ]; then
    echo "RHDH is ready with Orchestrator plugins."
    break
  fi
  if [ "$i" -eq 90 ]; then
    echo "WARNING: RHDH not ready after 7.5 minutes."
  fi
  sleep 5
done
echo ""

echo "=== Deployment Complete ==="
echo ""
echo "Access:"
echo "  RHDH:         https://backstage-rhdh.${BASE_DOMAIN}"
echo "  GitLab:       https://gitlab.${BASE_DOMAIN}"
echo "  Keycloak:     https://keycloak.${BASE_DOMAIN}"
echo "  ArgoCD:       https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || echo 'openshift-gitops-server-openshift-gitops.'${BASE_DOMAIN})"
echo "  Orchestrator: https://backstage-rhdh.${BASE_DOMAIN}/orchestrator"
echo ""
echo "GitLab admin:   root / ${GITLAB_ADMIN_PASSWORD}"
echo "Keycloak admin: admin / ${KEYCLOAK_ADMIN_PASSWORD}"
echo "Demo users (password: ${DEMO_PASSWORD}):"
echo "  vm-requestor, app-owner, security-admin, platform-admin"
echo "  frontend-dev, backend-dev (developers group)"
