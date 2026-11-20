#!/bin/bash
# Lifecycle through Git: change releases.yml on a branch and open a pull request.
#
# Usage:
#   gitops/scripts/release.sh promote ENV [VERSION] [--open-pr|--merge]
#       ENV = dev|qa|prod (any case). VERSION = RHEL9-FullStack version such
#       as 3.0 or 3.1 (incremental update). Default: what the previous stage
#       declares (qa <- Dev, prod <- QA); for dev the newest published version.
#   gitops/scripts/release.sh record [--open-pr|--merge]
#       write what Satellite serves NOW into releases.yml, for every environment
#       that differs: records a promotion or an incremental update done in the
#       Satellite UI (or hammer), so Git and Satellite agree again.
#   gitops/scripts/release.sh rollback [--open-pr|--merge]
#       reverts the last commit on main that changed satellite/releases.yml
#
# Without flags the branch is pushed and the Gitea compare link printed, so
# the PR is opened and merged in the UI, in front of the audience.
# The same edit can be made directly in the Gitea web editor
# ("Edit file" -> "Create a new branch for this commit and start a pull request").
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

usage() { sed -n '2,19p' "$0"; exit 1; }
ACTION="${1:-}"; shift || true
OPEN_PR=false; MERGE=false; POS=()
for a in "$@"; do
  case "$a" in
    --open-pr) OPEN_PR=true ;;
    --merge) OPEN_PR=true; MERGE=true ;;
    -h|--help) usage ;;
    *) POS+=("$a") ;;
  esac
done
require_cmd git

GITEA_HTTP="$(gitea_url)"
REMOTE="https://${GITEA_USER}:$(gitea_token)@$(gitea_host)/${GITEA_USER}/${GITEA_REPO}.git"
export GIT_SSL_NO_VERIFY=true
GIT_ID=(-c "user.name=${USER:-presenter}" -c "user.email=${USER:-presenter}@example.com")
REL="satellite/releases.yml"

if [ -d "${FLEET_CLONE_DIR}/.git" ]; then
  git -C "${FLEET_CLONE_DIR}" remote set-url origin "${REMOTE}"
  git -C "${FLEET_CLONE_DIR}" fetch -q --prune origin
  git -C "${FLEET_CLONE_DIR}" checkout -q -f -B main origin/main
else
  mkdir -p "$(dirname "${FLEET_CLONE_DIR}")"
  git clone -q "${REMOTE}" "${FLEET_CLONE_DIR}"
fi
cd "${FLEET_CLONE_DIR}"

declared() { sed -nE "s/^  $1: \"?([0-9.]+)\"?.*/\\1/p" "${REL}"; }
set_declared() { sed -i -E "s|^(  $1: ).*|\\1\"$2\"|" "${REL}"; }

case "${ACTION}" in
  promote)
    ENV=$(lce_name "${POS[0]:-}") || die "ENV must be dev, qa or prod"
    VER="${POS[1]:-}"
    if [ -z "${VER}" ]; then
      case "${ENV}" in
        Dev)  VER=$(satellite_latest_version) || true
              [ -n "${VER}" ] || die "could not read the newest RHEL9-FullStack version; pass VERSION" ;;
        QA)   VER=$(declared Dev) ;;
        Prod) VER=$(declared QA) ;;
      esac
      log "${ENV} gets ${VER} (default: $([ "${ENV}" = Dev ] && echo 'newest published version' || echo 'what the previous stage declares'))"
    fi
    [[ "${VER}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "VERSION must look like 3.0 or 3.1"
    [[ "${VER}" == *.* ]] || VER="${VER}.0"
    CUR=$(declared "${ENV}")
    [ "${CUR}" = "${VER}" ] && die "${ENV} already declares ${VER}"
    # Tell the presenter when the Satellite UI got there first: then this PR
    # records a promotion instead of triggering one.
    if SAT=$(satellite_releases 2>/dev/null); then
      for kv in ${SAT}; do
        [ "${kv%%=*}" = "${ENV}" ] && [ "${kv#*=}" = "${VER}" ] \
          && log "Satellite already serves ${ENV}=${VER} (promoted outside Git): this PR records it, the Job changes nothing"
      done
    fi
    BRANCH="release-${ENV,,}-${VER}"
    TITLE="Promote ${ENV}: ${CUR} -> ${VER}"
    git checkout -q -B "${BRANCH}"
    set_declared "${ENV}" "${VER}"
    git add "${REL}"
    git "${GIT_ID[@]}" commit -q -m "${TITLE}" -m "satellite/releases.yml: ${ENV} serves RHEL9-FullStack ${VER} after merge (the satellite-cac Job promotes)."
    ;;
  record)
    SAT=$(satellite_releases) || die "could not read RHEL9-FullStack versions from Satellite"
    CHANGES=()
    for kv in ${SAT}; do
      k="${kv%%=*}"; v="${kv#*=}"
      cur=$(declared "${k}")
      if [ "${cur}" != "${v}" ]; then
        set_declared "${k}" "${v}"
        CHANGES+=("${k} ${cur} -> ${v}")
      fi
    done
    [ ${#CHANGES[@]} -gt 0 ] || die "Git already matches Satellite (${SAT})"
    TITLE="Record Satellite state: $(IFS=,; echo "${CHANGES[*]}" | sed 's/,/, /g')"
    # hotfix.sh leaves "<Env> <version> <erratum>" behind; name the erratum if it explains a change
    if [ -s "${CACHE_DIR}/last-hotfix" ]; then
      read -r HF_ENV HF_VER HF_ERR < "${CACHE_DIR}/last-hotfix"
      printf '%s\n' "${CHANGES[@]}" | grep -q "^${HF_ENV} .* -> ${HF_VER}$" && TITLE="${TITLE} (incremental update: ${HF_ERR})"
    fi
    BRANCH="record-$(date +%H%M%S)"
    git checkout -q -B "${BRANCH}"
    git add "${REL}"
    git "${GIT_ID[@]}" commit -q -m "${TITLE}" \
      -m "Changed in the Satellite UI or with hammer; this commit makes Git agree."
    ;;
  rollback)
    LAST=$(git log -1 --format=%H -- "${REL}")
    [ -n "${LAST}" ] || die "no commit touching ${REL}"
    [ "$(git rev-list --count HEAD -- "${REL}")" -gt 1 ] || die "only the initial commit touched ${REL}; nothing to roll back"
    SUBJ=$(git log -1 --format=%s "${LAST}")
    BRANCH="rollback-$(git rev-parse --short "${LAST}")"
    git checkout -q -B "${BRANCH}"
    BEFORE=$(for e in Dev QA Prod; do echo "${e}=$(declared ${e})"; done)
    git "${GIT_ID[@]}" revert --no-edit "${LAST}" >/dev/null
    # Title says where each environment goes back to, e.g. "Rollback Prod: 5.1 -> 5.0"
    CH=()
    for kv in ${BEFORE}; do
      e="${kv%%=*}"; old="${kv#*=}"; new=$(declared "${e}")
      [ "${old}" != "${new}" ] && CH+=("${e}: ${old} -> ${new}")
    done
    TITLE="Rollback $(IFS=,; echo "${CH[*]:-releases.yml}" | sed 's/,/, /g')"
    BODY="Reverts \"${SUBJ}\" (${LAST:0:10})."
    git "${GIT_ID[@]}" commit -q --amend -m "${TITLE}" -m "${BODY}" -m "This reverts commit ${LAST}."
    ;;
  *) usage ;;
esac

git push -q --force origin "${BRANCH}"
echo "${TITLE}"
git --no-pager diff --color=always HEAD~1 -- "${REL}" | sed 's/^/  /'
echo

# Argo CD skips the auto-sync of a commit merged while a sync is running, so
# a PR merged during a running satellite-cac Job would never get its own Job.
if satellite_apply_busy; then
  warn "satellite-config is syncing right now (a Job runs): merge this PR only after it has finished, or press Sync afterwards"
fi

if [ "${OPEN_PR}" != "true" ]; then
  echo "Open the pull request in Gitea:"
  echo "  ${GITEA_HTTP}/${GITEA_USER}/${GITEA_REPO}/compare/main...${BRANCH}"
  exit 0
fi
PR=$(gitea_pr "${BRANCH}" "${TITLE}" "$(git log -1 --format=%b; echo; echo "Opened by release.sh (${ACTION}) as ${USER:-presenter}.")")
echo "Pull request #${PR}: ${GITEA_HTTP}/${GITEA_USER}/${GITEA_REPO}/pulls/${PR}"
if [ "${MERGE}" = "true" ]; then
  for _ in $(seq 1 60); do   # argo executor: wait for a running Job (see above), max 5 min
    satellite_apply_busy || break
    sleep 5
  done
  gitea_merge "${PR}"
  [ "${SATELLITE_EXECUTOR}" = "argo" ] && argocd_refresh satellite-config
  echo "Merged. Satellite applies it in ~1.5 min: $(satellite_apply_where)"
fi
