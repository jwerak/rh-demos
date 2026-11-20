#!/bin/bash
# Incremental update: copy ONE erratum into the content view version an
# environment serves, without publishing anything else. The composite
# RHEL9-FullStack gets a new minor version (2.0 -> 2.1) in that environment.
#
# Usage: gitops/scripts/hotfix.sh ERRATUM_ID [dev|qa|prod]     default: prod
#
# Same as Satellite UI: Content -> Content Views -> Demo-App-CV -> Versions ->
# (version used by the environment) -> Errata -> select -> "Apply" (incremental
# update, propagate to composites). Afterwards record it in Git:
#   gitops/scripts/release.sh record
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

ERRATUM="${1:-}"; [ -n "${ERRATUM}" ] || { sed -n '2,12p' "$0"; exit 1; }
ENV=$(lce_name "${2:-prod}") || die "environment must be dev, qa or prod"
SAT_URL="https://${SAT_FQDN}"
api() { curl -K <(printf 'user = "admin:%s"\n' "$(_curl_cfg_quote "${DEMO_PASSWORD}")") -sSk --fail-with-body -H 'Content-Type: application/json' "$@"; }

# Which Demo-App-CV version does the composite in ENV contain? Components of
# a composite version come from ?composite_version_id=<id>.
ORG_ID=$(api "${SAT_URL}/katello/api/organizations" | python3 -I -c 'import json,sys; print(next(o["id"] for o in json.load(sys.stdin)["results"] if o["name"]=="Demo_Org"))')
CV_ID=$(api "${SAT_URL}/katello/api/content_views?organization_id=${ORG_ID}&search=name=RHEL9-FullStack" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["id"])')
VER_ID=$(api "${SAT_URL}/katello/api/content_view_versions?content_view_id=${CV_ID}&per_page=200" | python3 -I -c '
import json, sys
print(next((str(v["id"]) for v in json.load(sys.stdin)["results"] if any(e["name"] == sys.argv[1] for e in v.get("environments", []))), ""))' "${ENV}")
[ -n "${VER_ID}" ] || die "no RHEL9-FullStack version found in ${ENV}"
COMPOSITE_VER=$(api "${SAT_URL}/katello/api/content_view_versions/${VER_ID}" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["version"])')
read -r COMPONENT_ID COMPONENT_VER < <(api "${SAT_URL}/katello/api/content_view_versions?composite_version_id=${VER_ID}" | python3 -I -c '
import json, sys
c = next(c for c in json.load(sys.stdin)["results"] if c["content_view"]["name"] == "Demo-App-CV")
print(c["id"], c["version"])')
[ -n "${COMPONENT_ID:-}" ] || die "no RHEL9-FullStack version found in ${ENV}"
log "${ENV} serves RHEL9-FullStack ${COMPOSITE_VER}, which contains Demo-App-CV ${COMPONENT_VER} (id ${COMPONENT_ID})"
log "Incremental update: ${ERRATUM} -> Demo-App-CV ${COMPONENT_VER}, propagated to the composite"
T0=$(date +%s)
# No --lifecycle-environments: the component version is usually in no
# environment at all (a newer Demo-App-CV is in Library), and naming one it is
# not in fails. --propagate-all-composites puts the new composite minor
# version into the environments of the composite it replaces.
sat_hammer "content-view version incremental-update --content-view-version-id ${COMPONENT_ID} --errata-ids ${ERRATUM} --propagate-all-composites true --organization Demo_Org --description Hotfix\\ ${ERRATUM}" \
  | tr '\r' '\n' | grep -vE '^Task .* (running|planned)|^$' | tail -6
NOW=$(satellite_releases || echo '?')
log "Done in $(( $(date +%s) - T0 )) s. Satellite now serves: ${NOW}"
# For release.sh record: name the erratum in the PR title
NEWVER=$(sed -nE "s/.*${ENV}=([0-9.]+).*/\1/p" <<<"${NOW}")
[ -n "${NEWVER}" ] && echo "${ENV} ${NEWVER} ${ERRATUM}" > "${CACHE_DIR}/last-hotfix"
cat <<EOF
Record it in Git (Git still declares the old version; the Job reports DRIFT until then):
  gitops/scripts/release.sh record
EOF
