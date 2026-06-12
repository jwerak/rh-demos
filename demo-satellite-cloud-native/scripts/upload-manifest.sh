#!/bin/bash
set -euo pipefail

NAMESPACE="satellite-cloud-native"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${DEMO_PASSWORD:-}" ] && [ -f "${SCRIPT_DIR}/../.env" ]; then
  source "${SCRIPT_DIR}/../.env"
fi
: "${DEMO_PASSWORD:?DEMO_PASSWORD not set. Run: source .env}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

MANIFEST_FILE="${MANIFEST_PATH:-${1:-}}"

if [ -z "${MANIFEST_FILE}" ]; then
  echo "Error: No manifest file specified."
  echo ""
  echo "Usage:"
  echo "  export MANIFEST_PATH=/path/to/manifest.zip"
  echo "  $0"
  echo ""
  echo "  Or: $0 /path/to/manifest.zip"
  echo ""
  echo "Download your manifest from:"
  echo "  https://access.redhat.com -> Subscriptions -> Subscription Allocations"
  exit 1
fi

if [ ! -f "${MANIFEST_FILE}" ]; then
  echo "Error: File not found: ${MANIFEST_FILE}"
  exit 1
fi

echo "Uploading manifest to Satellite VM ($(stat -c%s "${MANIFEST_FILE}") bytes)..."
sshpass -p "${DEMO_PASSWORD}" scp ${SSH_OPTS} \
  -o ProxyCommand="virtctl port-forward --stdio vmi/satellite.${NAMESPACE} 22" \
  "${MANIFEST_FILE}" cloud-user@localhost:/tmp/manifest.zip

echo "Importing manifest into Satellite..."
sshpass -p "${DEMO_PASSWORD}" ssh ${SSH_OPTS} \
  -o ProxyCommand="virtctl port-forward --stdio vmi/satellite.${NAMESPACE} 22" \
  cloud-user@localhost "sudo bash -c '
hammer subscription upload \
  --file /tmp/manifest.zip \
  --organization \"Demo_Org\"

if hammer repository-set list --organization \"Demo_Org\" --per-page 1 2>/dev/null | grep -q \"Red Hat\"; then
  echo \"\"
  echo \"Enabling RHEL 9 BaseOS + AppStream repos...\"
  hammer repository-set enable \
    --name \"Red Hat Enterprise Linux 9 for x86_64 - BaseOS (RPMs)\" \
    --product \"Red Hat Enterprise Linux for x86_64\" \
    --basearch x86_64 \
    --releasever 9 \
    --organization \"Demo_Org\" || true

  hammer repository-set enable \
    --name \"Red Hat Enterprise Linux 9 for x86_64 - AppStream (RPMs)\" \
    --product \"Red Hat Enterprise Linux for x86_64\" \
    --basearch x86_64 \
    --releasever 9 \
    --organization \"Demo_Org\" || true

  echo \"\"
  echo \"Starting repo sync (background, takes 10-60 minutes)...\"
  hammer repository synchronize \
    --name \"Red Hat Enterprise Linux 9 for x86_64 - BaseOS RPMs 9\" \
    --product \"Red Hat Enterprise Linux for x86_64\" \
    --organization \"Demo_Org\" \
    --async || true

  hammer repository synchronize \
    --name \"Red Hat Enterprise Linux 9 for x86_64 - AppStream RPMs 9\" \
    --product \"Red Hat Enterprise Linux for x86_64\" \
    --organization \"Demo_Org\" \
    --async || true

  echo \"\"
  echo \"Adding repos to content view...\"
  for REPO_NAME in \"Red Hat Enterprise Linux 9 for x86_64 - BaseOS RPMs 9\" \"Red Hat Enterprise Linux 9 for x86_64 - AppStream RPMs 9\"; do
    hammer content-view add-repository \
      --name \"RHEL9-Base\" \
      --repository \"\${REPO_NAME}\" \
      --product \"Red Hat Enterprise Linux for x86_64\" \
      --organization \"Demo_Org\" || true
  done

  echo \"\"
  echo \"Waiting for repo sync to complete...\"
  for TASK_ID in \$(hammer --csv task list --search \"action ~ synchronize and state = running\" 2>/dev/null | tail -n +2 | cut -d, -f1); do
    hammer task progress --id \"\${TASK_ID}\" 2>/dev/null || true
  done

  echo \"\"
  echo \"Republishing content view...\"
  hammer content-view publish \
    --name \"RHEL9-Base\" \
    --organization \"Demo_Org\"

  LATEST_VERSION=\$(hammer --csv content-view version list --content-view \"RHEL9-Base\" --organization \"Demo_Org\" 2>/dev/null | tail -n +2 | sort -t, -k3 -rn | head -1 | cut -d, -f1)
  hammer content-view version promote \
    --id \"\${LATEST_VERSION}\" \
    --to-lifecycle-environment \"Lab\" \
    --organization \"Demo_Org\"

  echo \"\"
  echo \"Done. Satellite is now serving RHEL 9 packages.\"
  echo \"Clients can install packages via: dnf install <package>\"
else
  echo \"\"
  echo \"WARNING: Manifest imported but no Red Hat repository sets found.\"
  echo \"The manifest may not have active subscriptions attached.\"
  echo \"Attach subscriptions at: https://access.redhat.com -> Subscription Allocations\"
fi

rm -f /tmp/manifest.zip
'"
