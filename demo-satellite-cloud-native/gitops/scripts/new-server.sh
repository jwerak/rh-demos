#!/bin/bash
# V2 - a server is a file in Git; it exists once a pull request is merged.
#
# Usage: gitops/scripts/new-server.sh NAME [dev|qa|prod] [small|medium|large] [--open-pr] [--merge]
#   default    render fleet/<env>/<NAME>.yaml in a local clone, commit on branch
#              add-<NAME>, push, print the Gitea "new pull request" link.
#              The presenter opens and merges the PR in the Gitea UI.
#   --open-pr  also open the pull request through the API
#   --merge    also merge it (implies --open-pr), i.e. no human in the loop
#
# Local clone: ~/.cache/satellite-demo/rhel-fleet (re-used, reset to main).
# Decommission = a PR that deletes the file; Argo CD prunes the VM.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

OPEN_PR=false; MERGE=false; POS=()
for a in "$@"; do
  case "$a" in
    --open-pr) OPEN_PR=true ;;
    --merge) OPEN_PR=true; MERGE=true ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) POS+=("$a") ;;
  esac
done
NAME="${POS[0]:-}"; ENV="${POS[1]:-dev}"; SIZE="${POS[2]:-small}"
[ -n "${NAME}" ] || { sed -n '2,14p' "$0"; exit 1; }
require_cmd git

GITEA_HTTP="$(gitea_url)"
REMOTE="https://${GITEA_USER}:$(gitea_token)@$(gitea_host)/${GITEA_USER}/${GITEA_REPO}.git"
BRANCH="add-${NAME}"
FILE="fleet/${ENV}/${NAME}.yaml"
export GIT_SSL_NO_VERIFY=true

if [ -d "${FLEET_CLONE_DIR}/.git" ]; then
  git -C "${FLEET_CLONE_DIR}" remote set-url origin "${REMOTE}"
  git -C "${FLEET_CLONE_DIR}" fetch -q --prune origin
  git -C "${FLEET_CLONE_DIR}" checkout -q -f -B main origin/main
else
  mkdir -p "$(dirname "${FLEET_CLONE_DIR}")"
  git clone -q "${REMOTE}" "${FLEET_CLONE_DIR}"
fi
cd "${FLEET_CLONE_DIR}"

[ -e "${FILE}" ] && die "${FILE} already exists on main"
git checkout -q -B "${BRANCH}"
mkdir -p "fleet/${ENV}"
render_vm "${NAME}" "${ENV}" "${SIZE}" git-pr "${PWD}/${FILE}"
git add "${FILE}"
git -c user.name="${USER:-presenter}" -c user.email="${USER:-presenter}@example.com" \
  commit -q -m "Add server ${NAME} (${ENV}, ${SIZE})"
git push -q --force origin "${BRANCH}"

echo
echo "Branch ${BRANCH} pushed with ${FILE}:"
git --no-pager show --stat --oneline HEAD | sed 's/^/  /'
echo

if [ "${OPEN_PR}" != "true" ]; then
  echo "Open the pull request in Gitea:"
  echo "  ${GITEA_HTTP}/${GITEA_USER}/${GITEA_REPO}/compare/main...${BRANCH}"
  exit 0
fi

PR=$(gitea_pr "${BRANCH}" "Add server ${NAME} (${ENV}, ${SIZE})" "Requested by ${USER:-presenter} via new-server.sh")
echo "Pull request #${PR}: ${GITEA_HTTP}/${GITEA_USER}/${GITEA_REPO}/pulls/${PR}"

if [ "${MERGE}" = "true" ]; then
  gitea_merge "${PR}"
  argocd_refresh rhel-fleet
  echo "Merged at $(date +%T). Argo CD syncs within a minute (or press Refresh on rhel-fleet)."
fi
