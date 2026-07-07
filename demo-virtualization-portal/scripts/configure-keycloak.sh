#!/bin/bash
set -euo pipefail

: "${BASE_DOMAIN:?ERROR: BASE_DOMAIN must be set}"
: "${KEYCLOAK_ADMIN_PASSWORD:?ERROR: KEYCLOAK_ADMIN_PASSWORD must be set}"
: "${KEYCLOAK_CLIENT_SECRET:?ERROR: KEYCLOAK_CLIENT_SECRET must be set}"

KC_URL="https://keycloak.${BASE_DOMAIN}"
KC_API="${KC_URL}/admin/realms/virt-portal"

echo "=== Configuring Keycloak ==="

echo "Waiting for virt-portal realm..."
for i in $(seq 1 60); do
  if curl -ksS -o /dev/null -w "%{http_code}" "${KC_URL}/realms/virt-portal" 2>/dev/null | grep -q 200; then
    echo "virt-portal realm is ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: virt-portal realm not available after 5 minutes."
    exit 1
  fi
  sleep 5
done

# Get admin token
ADMIN_TOKEN=$(curl -ksS -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "grant_type=password" \
  -d "username=admin" -d "password=${KEYCLOAK_ADMIN_PASSWORD}" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

auth() { echo "Authorization: Bearer $ADMIN_TOKEN"; }

# Create standard OIDC scopes (realm import doesn't auto-create them)
echo "Creating OIDC scopes..."
for SCOPE_JSON in \
  '{"name":"openid","protocol":"openid-connect","attributes":{"include.in.token.scope":"true"}}' \
  '{"name":"profile","protocol":"openid-connect","attributes":{"include.in.token.scope":"true"},"protocolMappers":[{"name":"username","protocol":"openid-connect","protocolMapper":"oidc-usermodel-attribute-mapper","config":{"claim.name":"preferred_username","user.attribute":"username","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true","jsonType.label":"String"}},{"name":"full name","protocol":"openid-connect","protocolMapper":"oidc-full-name-mapper","config":{"id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}]}' \
  '{"name":"email","protocol":"openid-connect","attributes":{"include.in.token.scope":"true"},"protocolMappers":[{"name":"email","protocol":"openid-connect","protocolMapper":"oidc-usermodel-attribute-mapper","config":{"claim.name":"email","user.attribute":"email","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true","jsonType.label":"String"}}]}'; do
  curl -ksS -X POST -H "$(auth)" -H "Content-Type: application/json" \
    -d "$SCOPE_JSON" "${KC_API}/client-scopes" -o /dev/null 2>/dev/null
done

# Add scopes to RHDH client
echo "Assigning scopes to RHDH client..."
CLIENT_UUID=$(curl -ksS -H "$(auth)" "${KC_API}/clients?clientId=rhdh" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
for SCOPE_NAME in openid profile email; do
  SCOPE_ID=$(curl -ksS -H "$(auth)" "${KC_API}/client-scopes" | python3 -c "import sys,json; scopes={s['name']:s['id'] for s in json.load(sys.stdin)}; print(scopes.get('$SCOPE_NAME',''))")
  [ -n "$SCOPE_ID" ] && curl -ksS -X PUT -H "$(auth)" "${KC_API}/clients/$CLIENT_UUID/default-client-scopes/$SCOPE_ID" -o /dev/null 2>/dev/null
done

# Assign realm-management roles to service account (for RHDH catalog provider)
echo "Configuring service account roles..."
SA_USER_ID=$(curl -ksS -H "$(auth)" "${KC_API}/clients/$CLIENT_UUID/service-account-user" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
RM_CLIENT_ID=$(curl -ksS -H "$(auth)" "${KC_API}/clients?clientId=realm-management" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
ROLES_JSON=$(curl -ksS -H "$(auth)" "${KC_API}/clients/$RM_CLIENT_ID/roles" | python3 -c "
import sys,json
roles = json.load(sys.stdin)
needed = ['view-users', 'view-realm', 'query-groups', 'query-users']
print(json.dumps([{'id': r['id'], 'name': r['name']} for r in roles if r['name'] in needed]))
")
curl -ksS -X POST -H "$(auth)" -H "Content-Type: application/json" \
  -d "$ROLES_JSON" "${KC_API}/users/$SA_USER_ID/role-mappings/clients/$RM_CLIENT_ID" -o /dev/null 2>/dev/null

echo "Keycloak configured."
