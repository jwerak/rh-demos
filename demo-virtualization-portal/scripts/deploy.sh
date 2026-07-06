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

echo "=== Deployment Complete ==="
echo ""
echo "Access:"
echo "  RHDH:     https://backstage-rhdh.${BASE_DOMAIN}"
echo "  GitLab:   https://gitlab.${BASE_DOMAIN}"
echo "  Keycloak: https://keycloak.${BASE_DOMAIN}"
echo "  ArgoCD:   https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || echo 'openshift-gitops-server-openshift-gitops.'${BASE_DOMAIN})"
echo ""
echo "GitLab admin:   root / ${GITLAB_ADMIN_PASSWORD}"
echo "Keycloak admin: admin / ${KEYCLOAK_ADMIN_PASSWORD}"
echo "Demo users (password: ${DEMO_PASSWORD}):"
echo "  vm-requestor, app-owner, security-admin, platform-admin"
