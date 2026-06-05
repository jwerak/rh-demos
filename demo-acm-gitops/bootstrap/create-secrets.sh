#!/usr/bin/env bash
set -euo pipefail

# Usage: create-secrets.sh <cluster-name> [namespace]
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <cluster-name> [namespace]"
  echo "  cluster-name  Name of the hosted cluster (required)"
  echo "  namespace     Target namespace (default: clusters)"
  exit 1
fi

CLUSTER_NAME="$1"
NAMESPACE="${2:-clusters}"

oc extract secret/pull-secret -n openshift-config --to=- \
  | oc create secret generic "pullsecret-cluster-${CLUSTER_NAME}" \
      -n "${NAMESPACE}" \
      --from-file=.dockerconfigjson=/dev/stdin \
      --type=kubernetes.io/dockerconfigjson

ssh-keygen -t ed25519 -N '' -f "/tmp/${CLUSTER_NAME}-ssh-key" -C "${CLUSTER_NAME}" <<< y >/dev/null 2>&1
oc create secret generic "sshkey-cluster-${CLUSTER_NAME}" \
  -n "${NAMESPACE}" \
  --from-file=id_ed25519="/tmp/${CLUSTER_NAME}-ssh-key" \
  --from-file=id_ed25519.pub="/tmp/${CLUSTER_NAME}-ssh-key.pub"
rm -f "/tmp/${CLUSTER_NAME}-ssh-key" "/tmp/${CLUSTER_NAME}-ssh-key.pub"

ETCD_KEY=$(openssl rand -base64 32)
oc create secret generic "${CLUSTER_NAME}-etcd-encryption-key" \
  -n "${NAMESPACE}" \
  --from-literal=key="${ETCD_KEY}"
