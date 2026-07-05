#!/bin/bash
set -euo pipefail

echo "=== VM Self-Service Portal Teardown ==="
echo ""

echo "--- Deleting ArgoCD Applications ---"
oc delete application virt-portal-demo-env -n openshift-gitops --ignore-not-found
oc delete application virt-portal-rhdh -n openshift-gitops --ignore-not-found
oc delete application virt-portal-gitea -n openshift-gitops --ignore-not-found
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

echo "--- Deleting namespaces ---"
for ns in vm-dev vm-staging vm-prod rhdh gitea rhdh-operator; do
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
