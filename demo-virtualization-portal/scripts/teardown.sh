#!/bin/bash
set -euo pipefail

echo "=== VM Self-Service Portal Teardown ==="
echo ""

echo "--- Deleting VM ApplicationSet ---"
oc delete applicationset vm-instances -n openshift-gitops --ignore-not-found
oc delete secret gitlab-scm-token -n openshift-gitops --ignore-not-found
echo ""

echo "--- Deleting ArgoCD Applications ---"
oc delete application virt-portal-demo-env -n openshift-gitops --ignore-not-found
oc delete application virt-portal-operators -n openshift-gitops --ignore-not-found
echo ""

echo "--- Deleting VMs in demo namespaces ---"
for ns in vm-dev vm-staging vm-prod; do
  if oc get namespace "${ns}" &>/dev/null; then
    oc delete vm --all -n "${ns}" --ignore-not-found 2>/dev/null || true
    echo "  Cleared VMs in ${ns}"
  fi
done
echo ""

echo "--- Deleting RHDH instance ---"
oc delete backstage rhdh -n rhdh --ignore-not-found 2>/dev/null || true
echo ""

echo "--- Deleting Orchestrator resources ---"
oc delete sonataflow --all -n rhdh --ignore-not-found 2>/dev/null || true
oc delete sonataflowplatform sonataflow-platform -n rhdh --ignore-not-found 2>/dev/null || true
oc delete secret workflow-credentials sonataflow-db-credentials -n rhdh --ignore-not-found 2>/dev/null || true
echo ""

echo "--- Deleting Serverless Logic Operator ---"
oc delete subscription logic-operator-rhel8 -n openshift-serverless-logic --ignore-not-found 2>/dev/null || true
oc delete csv -n openshift-serverless-logic -l operators.coreos.com/logic-operator-rhel8.openshift-serverless-logic --ignore-not-found 2>/dev/null || true
echo ""

echo "--- Deleting Serverless Operator ---"
oc delete subscription serverless-operator -n openshift-serverless --ignore-not-found 2>/dev/null || true
oc delete csv -n openshift-serverless -l operators.coreos.com/serverless-operator.openshift-serverless --ignore-not-found 2>/dev/null || true
echo ""

echo "--- Deleting Gatekeeper policies ---"
for f in vm-naming vm-resource-limits vm-required-labels; do
  oc delete constraint "${f}" --ignore-not-found 2>/dev/null || true
done
for f in vmnamingconvention vmresourcelimits vmrequiredlabels; do
  oc delete constrainttemplate "${f}" --ignore-not-found 2>/dev/null || true
done
oc delete gatekeeper gatekeeper --ignore-not-found 2>/dev/null || true
echo ""

echo "--- Deleting Gatekeeper Operator ---"
oc delete subscription gatekeeper-operator-product -n openshift-gatekeeper-system --ignore-not-found 2>/dev/null || true
oc delete csv -n openshift-gatekeeper-system -l operators.coreos.com/gatekeeper-operator-product.openshift-gatekeeper-system --ignore-not-found 2>/dev/null || true
echo ""

echo "--- Deleting namespaces ---"
for ns in vm-dev vm-staging vm-prod rhdh gitlab keycloak rhdh-operator openshift-gatekeeper-system openshift-serverless openshift-serverless-logic; do
  oc delete namespace "${ns}" --ignore-not-found 2>/dev/null || true
  echo "  Deleted namespace: ${ns}"
done
echo ""

echo "--- Deleting RBAC ---"
oc delete clusterrolebinding argocd-virt-portal --ignore-not-found
oc delete clusterrole argocd-virt-portal --ignore-not-found
echo ""

echo "--- Deleting RHDH Operator Subscription ---"
oc delete subscription rhdh -n rhdh-operator --ignore-not-found 2>/dev/null || true
oc delete csv -n rhdh-operator -l operators.coreos.com/rhdh.rhdh-operator --ignore-not-found 2>/dev/null || true
echo ""

echo "--- Deleting demo htpasswd ---"
oc delete secret demo-htpasswd -n openshift-config --ignore-not-found 2>/dev/null || true
echo ""

echo "=== Teardown Complete ==="
echo ""
echo "NOTE: OpenShift GitOps Operator was NOT removed (may be shared)."
echo "To remove it: oc delete subscription openshift-gitops-operator -n openshift-operators"
