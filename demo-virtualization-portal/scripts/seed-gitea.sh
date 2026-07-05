#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="${SCRIPT_DIR}/.."

: "${BASE_DOMAIN:?ERROR: BASE_DOMAIN must be set}"
: "${GITEA_ADMIN_USER:?ERROR: GITEA_ADMIN_USER must be set}"
: "${GITEA_ADMIN_PASSWORD:?ERROR: GITEA_ADMIN_PASSWORD must be set}"

GITEA_URL="https://gitea-gitea.${BASE_DOMAIN}"
GITEA_API="${GITEA_URL}/api/v1"
AUTH="-u ${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}"
CURL_OPTS="-k"

echo "=== Seeding Gitea at ${GITEA_URL} ==="
echo ""

api() {
  local method="$1" endpoint="$2"
  shift 2
  curl ${CURL_OPTS} -sSf -X "${method}" ${AUTH} \
    -H "Content-Type: application/json" \
    "${GITEA_API}${endpoint}" "$@"
}

api_ignore_conflict() {
  local method="$1" endpoint="$2"
  shift 2
  local http_code
  http_code=$(curl ${CURL_OPTS} -sS -o /dev/null -w "%{http_code}" -X "${method}" ${AUTH} \
    -H "Content-Type: application/json" \
    "${GITEA_API}${endpoint}" "$@")
  if [ "${http_code}" -ge 400 ] && [ "${http_code}" -ne 409 ] && [ "${http_code}" -ne 422 ]; then
    echo "ERROR: ${method} ${endpoint} returned HTTP ${http_code}"
    return 1
  fi
}

# Create organizations
echo "--- Creating organizations ---"
for org in demo vm-instances; do
  api_ignore_conflict POST "/orgs" -d "{\"username\": \"${org}\", \"visibility\": \"public\"}"
  echo "  Organization: ${org}"
done
echo ""

# Create API token for RHDH integration
echo "--- Creating Gitea API token for RHDH ---"
TOKEN_RESPONSE=$(api POST "/users/${GITEA_ADMIN_USER}/tokens" \
  -d '{"name": "rhdh-integration", "scopes": ["all"]}' 2>/dev/null || true)

if [ -n "${TOKEN_RESPONSE}" ]; then
  GITEA_TOKEN=$(echo "${TOKEN_RESPONSE}" | grep -o '"sha1":"[^"]*"' | cut -d'"' -f4)
  if [ -z "${GITEA_TOKEN}" ]; then
    echo "  Token may already exist. Delete and recreate if needed:"
    echo "    curl -X DELETE ${AUTH} ${GITEA_API}/users/${GITEA_ADMIN_USER}/tokens/rhdh-integration"
  else
    echo "  Token created: ${GITEA_TOKEN}"
    echo ""
    echo "  Update the RHDH secret:"
    echo "    oc patch secret rhdh-secrets -n rhdh --type merge -p '{\"stringData\": {\"GITEA_TOKEN\": \"${GITEA_TOKEN}\"}}'"
  fi
else
  echo "  Could not create token (may already exist)."
fi
echo ""

# Push templates to Gitea
echo "--- Pushing templates to Gitea ---"

TEMPLATES_REPO="templates"
api_ignore_conflict POST "/orgs/demo/repos" \
  -d "{\"name\": \"${TEMPLATES_REPO}\", \"auto_init\": true, \"default_branch\": \"main\"}"

TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT

cd "${TMPDIR}"
git init -b main
git config user.email "admin@example.com"
git config user.name "Admin"
git config http.sslVerify false

cp -r "${BASE_DIR}/templates/"* .
git add -A
git commit -m "Initial template import"
git remote add origin "${GITEA_URL}/demo/${TEMPLATES_REPO}.git"
git push -u origin main --force 2>/dev/null || \
  git push "https://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}@gitea-gitea.${BASE_DOMAIN}/demo/${TEMPLATES_REPO}.git" main --force

echo "  Templates pushed to demo/${TEMPLATES_REPO}"
echo ""

echo "=== Gitea seeding complete ==="
