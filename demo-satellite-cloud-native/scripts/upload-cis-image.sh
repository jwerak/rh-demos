#!/bin/bash
set -euo pipefail

# Upload CIS Level 2 hardened RHEL 9 qcow2 image to OpenShift
# as a PVC for use by the compliant-client VM (Demo 12).
#
# Usage: ./scripts/upload-cis-image.sh /path/to/cis-rhel9.qcow2

NAMESPACE="satellite-cloud-native"
PVC_NAME="cis-rhel9-base"
PVC_SIZE="30Gi"

IMAGE_PATH="${1:-}"
if [ -z "${IMAGE_PATH}" ]; then
  echo "Usage: $0 <path-to-cis-rhel9.qcow2>"
  echo ""
  echo "Build a CIS Level 2 hardened RHEL 9 image with Image Builder:"
  echo "  composer-cli blueprints push cis-blueprint.toml"
  echo "  composer-cli compose start cis-rhel9 qcow2"
  echo "  composer-cli compose image <UUID>"
  exit 1
fi

if [ ! -f "${IMAGE_PATH}" ]; then
  echo "ERROR: File not found: ${IMAGE_PATH}"
  exit 1
fi

echo "=== Uploading CIS-hardened RHEL 9 image ==="
echo "  Image: ${IMAGE_PATH}"
echo "  PVC:   ${PVC_NAME} (${PVC_SIZE})"
echo "  NS:    ${NAMESPACE}"
echo ""

if oc get pvc "${PVC_NAME}" -n "${NAMESPACE}" > /dev/null 2>&1; then
  echo "PVC ${PVC_NAME} already exists. Deleting and re-uploading..."
  oc delete pvc "${PVC_NAME}" -n "${NAMESPACE}"
  sleep 5
fi

virtctl image-upload pvc "${PVC_NAME}" \
  --size="${PVC_SIZE}" \
  --image-path="${IMAGE_PATH}" \
  -n "${NAMESPACE}" \
  --insecure \
  --access-mode=ReadWriteOnce

echo ""
echo "=== Upload complete ==="
oc get pvc "${PVC_NAME}" -n "${NAMESPACE}" -o wide
echo ""
echo "Deploy the compliant VM with:"
echo "  ./scripts/demo-scenarios.sh 12"
