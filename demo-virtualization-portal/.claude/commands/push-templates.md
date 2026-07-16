Push RHDH Software Templates from local `templates/` directory to the on-cluster GitLab (`demo/templates` project). Replaces `__BASE_DOMAIN__` placeholders with the actual domain from `.env`.

Run this after modifying any template files (template.yaml, skeleton files) to update what RHDH shows in the Create menu.

## Steps

1. Source `.env` to get `BASE_DOMAIN` and `GITLAB_TOKEN`
2. Unprotect the `main` branch on the GitLab `demo/templates` project (needed for force push)
3. Copy `templates/*` to a temp directory
4. Replace `__BASE_DOMAIN__` with the actual domain in all YAML files
5. Force-push to `demo/templates` on GitLab
6. Clean up the temp directory

## Command

```bash
source .env

GITLAB_API="https://gitlab.${BASE_DOMAIN}/api/v4"

TEMPLATES_PROJECT_ID=$(curl -ks -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_API}/projects/demo%2Ftemplates" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [ -n "${TEMPLATES_PROJECT_ID}" ]; then
  curl -ks -o /dev/null -X DELETE \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_API}/projects/${TEMPLATES_PROJECT_ID}/protected_branches/main" || true
fi

TMPDIR=$(mktemp -d)
cd "${TMPDIR}"
git init -b main
git config user.email "admin@example.com"
git config user.name "Admin"
git config http.sslVerify false

cp -r "$(dirs -l +1)/templates/"* .
find . -type f -name '*.yaml' -exec sed -i "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" {} +

git add -A
git commit -m "Update templates"
git remote add origin "https://oauth2:${GITLAB_TOKEN}@gitlab.${BASE_DOMAIN}/demo/templates.git"
GIT_SSL_NO_VERIFY=true git push -u origin main --force

cd -
rm -rf "${TMPDIR}"
```
