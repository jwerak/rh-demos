#!/bin/bash
set -euo pipefail

: "${DEMO_PASSWORD:?ERROR: DEMO_PASSWORD must be set. Run: source .env}"

echo "=== Creating Demo Users (htpasswd) ==="
echo ""

HTPASSWD_FILE=$(mktemp)
trap "rm -f ${HTPASSWD_FILE}" EXIT

USERS=(admin developer approver viewer)

for user in "${USERS[@]}"; do
  htpasswd -bB "${HTPASSWD_FILE}" "${user}" "${DEMO_PASSWORD}"
  echo "  Created user: ${user}"
done

SECRET_NAME="demo-htpasswd"
if oc get secret "${SECRET_NAME}" -n openshift-config &>/dev/null; then
  oc delete secret "${SECRET_NAME}" -n openshift-config
fi
oc create secret generic "${SECRET_NAME}" \
  --from-file=htpasswd="${HTPASSWD_FILE}" \
  -n openshift-config

echo ""
echo "--- Configuring OAuth htpasswd identity provider ---"
oc patch oauth/cluster --type=merge -p '{
  "spec": {
    "identityProviders": [{
      "name": "demo-htpasswd",
      "type": "HTPasswd",
      "mappingMethod": "claim",
      "htpasswd": {
        "fileData": {
          "name": "demo-htpasswd"
        }
      }
    }]
  }
}'

echo ""
echo "=== Demo users created ==="
echo ""
echo "Users: ${USERS[*]}"
echo "Password: ${DEMO_PASSWORD}"
echo ""
echo "NOTE: If OAuth already has other identity providers configured,"
echo "this script may overwrite them. Check with: oc get oauth/cluster -o yaml"
