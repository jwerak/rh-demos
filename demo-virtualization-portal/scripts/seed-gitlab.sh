#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="${SCRIPT_DIR}/.."

: "${BASE_DOMAIN:?ERROR: BASE_DOMAIN must be set}"
: "${GITLAB_ADMIN_PASSWORD:?ERROR: GITLAB_ADMIN_PASSWORD must be set}"
: "${GITLAB_TOKEN:?ERROR: GITLAB_TOKEN must be set}"
: "${DEMO_PASSWORD:?ERROR: DEMO_PASSWORD must be set}"

GITLAB_URL="https://gitlab.${BASE_DOMAIN}"
GITLAB_API="${GITLAB_URL}/api/v4"
CURL_OPTS="-k"

echo "=== Seeding GitLab at ${GITLAB_URL} ==="
echo ""

api() {
  local method="$1" endpoint="$2"
  shift 2
  curl ${CURL_OPTS} -sSf -X "${method}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GITLAB_API}${endpoint}" "$@"
}

api_ignore_conflict() {
  local method="$1" endpoint="$2"
  shift 2
  local http_code
  http_code=$(curl ${CURL_OPTS} -sS -o /dev/null -w "%{http_code}" -X "${method}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GITLAB_API}${endpoint}" "$@")
  if [ "${http_code}" -ge 400 ] && [ "${http_code}" -ne 400 ] && [ "${http_code}" -ne 409 ] && [ "${http_code}" -ne 422 ]; then
    echo "ERROR: ${method} ${endpoint} returned HTTP ${http_code}"
    return 1
  fi
}

# Create PAT via rails runner
echo "--- Creating GitLab Personal Access Token ---"
GITLAB_POD=$(oc get pod -n gitlab -l app=gitlab -o jsonpath='{.items[0].metadata.name}')
oc exec -n gitlab "${GITLAB_POD}" -- gitlab-rails runner "
  token = PersonalAccessToken.find_by(name: 'rhdh')
  if token
    token.revoke! rescue nil
    token.destroy!
    puts 'Removed existing token'
  end
  user = User.find_by_username('root')
  token = user.personal_access_tokens.create!(
    name: 'rhdh',
    scopes: ['api', 'read_repository', 'write_repository'],
    expires_at: 365.days.from_now
  )
  token.set_token('${GITLAB_TOKEN}')
  token.save!
  puts 'Token created successfully'
" 2>/dev/null || echo "  Token may already exist."
echo ""

# Configure GitLab admin settings
echo "--- Configuring GitLab admin settings ---"
oc exec -n gitlab "${GITLAB_POD}" -- timeout 120 gitlab-rails runner \
  "ApplicationSetting.current.update_column(:deletion_adjourned_period, 0)" 2>/dev/null || true
echo "  Project deletion delay: 0 (immediate, via rails — API enforces min 1)"
echo ""

# Create groups
echo "--- Creating groups ---"
for group in demo vm-instances; do
  api_ignore_conflict POST "/groups" \
    -d "{\"name\": \"${group}\", \"path\": \"${group}\", \"visibility\": \"public\"}"
  echo "  Group: ${group}"
done
echo ""

# Configure vm-instances group: branch protection + MR approval
echo "--- Configuring vm-instances group (branch protection + approvals) ---"
VM_GROUP_ID=$(api GET "/groups/vm-instances" 2>/dev/null | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
if [ -n "${VM_GROUP_ID}" ]; then
  api PUT "/groups/${VM_GROUP_ID}" \
    -d '{"default_branch_protection": 2}' >/dev/null 2>&1 || true
  echo "  Default branch protection: Developers + Maintainers"

  # Require 2 approvals before merge at group level
  api PUT "/groups/${VM_GROUP_ID}" \
    -d '{"require_two_factor_authentication": false}' >/dev/null 2>&1 || true
fi
echo ""

# Create GitLab users for MR approval (matching Keycloak demo users)
echo "--- Creating GitLab users ---"
for user in app-owner security-admin; do
  api_ignore_conflict POST "/users" \
    -d "{\"username\": \"${user}\", \"name\": \"${user}\", \"email\": \"${user}@demo.local\", \"password\": \"${DEMO_PASSWORD}\", \"skip_confirmation\": true, \"force_random_password\": false}"
  echo "  User: ${user} (approval)"
done
for user in frontend-dev backend-dev; do
  api_ignore_conflict POST "/users" \
    -d "{\"username\": \"${user}\", \"name\": \"${user}\", \"email\": \"${user}@demo.local\", \"password\": \"${DEMO_PASSWORD}\", \"skip_confirmation\": true, \"force_random_password\": false}"
  echo "  User: ${user} (developer)"
done
echo ""

# Add approval users to vm-instances group as Maintainers
echo "--- Adding users to vm-instances group ---"
for user in app-owner security-admin; do
  USER_ID=$(api GET "/users?username=${user}" 2>/dev/null | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
  if [ -n "${USER_ID}" ]; then
    api_ignore_conflict POST "/groups/${VM_GROUP_ID}/members" \
      -d "{\"user_id\": ${USER_ID}, \"access_level\": 40}"
    echo "  ${user} → vm-instances (Maintainer)"
  fi
done
# Add developers as Reporters (can create issues, cannot approve MRs)
for user in frontend-dev backend-dev; do
  USER_ID=$(api GET "/users?username=${user}" 2>/dev/null | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
  if [ -n "${USER_ID}" ]; then
    api_ignore_conflict POST "/groups/${VM_GROUP_ID}/members" \
      -d "{\"user_id\": ${USER_ID}, \"access_level\": 20}"
    echo "  ${user} → vm-instances (Reporter)"
  fi
done
echo ""

# Create templates project in demo group
echo "--- Creating templates project ---"
DEMO_GROUP_ID=$(api GET "/groups/demo" 2>/dev/null | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
if [ -n "${DEMO_GROUP_ID}" ]; then
  api_ignore_conflict POST "/projects" \
    -d "{\"name\": \"templates\", \"namespace_id\": ${DEMO_GROUP_ID}, \"visibility\": \"public\", \"initialize_with_readme\": true, \"default_branch\": \"main\"}"
  echo "  Project: demo/templates"
fi
echo ""

# Push templates to GitLab
echo "--- Pushing templates to GitLab ---"

# Unprotect main branch to allow force push
TEMPLATES_PROJECT_ID=$(api GET "/projects/demo%2Ftemplates" 2>/dev/null | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
if [ -n "${TEMPLATES_PROJECT_ID}" ]; then
  curl ${CURL_OPTS} -sS -o /dev/null -X DELETE \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_API}/projects/${TEMPLATES_PROJECT_ID}/protected_branches/main" 2>/dev/null || true
fi

TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT

cd "${TMPDIR}"
git init -b main
git config user.email "admin@example.com"
git config user.name "Admin"
git config http.sslVerify false

cp -r "${BASE_DIR}/templates/"* .

# Replace __BASE_DOMAIN__ in template files before pushing
find . -type f -name '*.yaml' -exec sed -i "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" {} +

git add -A
git commit -m "Initial template import"
git remote add origin "https://oauth2:${GITLAB_TOKEN}@gitlab.${BASE_DOMAIN}/demo/templates.git"
GIT_SSL_NO_VERIFY=true git push -u origin main --force

echo "  Templates pushed to demo/templates"
echo ""

# Configure MR approval rules at group level
echo "--- Configuring MR approval rules ---"
if [ -n "${VM_GROUP_ID}" ]; then
  api_ignore_conflict PUT "/groups/${VM_GROUP_ID}" \
    -d '{"merge_requests_access_level": "enabled"}'
  echo "  MR approval: app-owner + security-admin can approve in vm-instances group"
  echo "  Branch protection: main branch requires MR (no direct push)"
fi
echo ""

# Create vm-approvals project for Orchestrator workflow approval issues
echo "--- Creating vm-approvals project ---"
if [ -n "${DEMO_GROUP_ID}" ]; then
  api_ignore_conflict POST "/projects" \
    -d "{\"name\": \"vm-approvals\", \"namespace_id\": ${DEMO_GROUP_ID}, \"visibility\": \"public\", \"initialize_with_readme\": true, \"default_branch\": \"main\"}"
  echo "  Project: demo/vm-approvals"

  # Create approval labels
  APPROVALS_PROJECT_ID=$(api GET "/projects/demo%2Fvm-approvals" 2>/dev/null | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
  if [ -n "${APPROVALS_PROJECT_ID}" ]; then
    api_ignore_conflict POST "/projects/${APPROVALS_PROJECT_ID}/labels" \
      -d '{"name": "approved", "color": "#69D100", "description": "VM request approved"}'
    api_ignore_conflict POST "/projects/${APPROVALS_PROJECT_ID}/labels" \
      -d '{"name": "denied", "color": "#D10069", "description": "VM request denied"}'
    api_ignore_conflict POST "/projects/${APPROVALS_PROJECT_ID}/labels" \
      -d '{"name": "vm-request", "color": "#428BCA", "description": "VM request issue"}'
    api_ignore_conflict POST "/projects/${APPROVALS_PROJECT_ID}/labels" \
      -d '{"name": "pending", "color": "#F0AD4E", "description": "Pending approval"}'
    echo "  Labels: approved, denied, vm-request, pending"
  fi
fi
echo ""

echo "=== GitLab seeding complete ==="
