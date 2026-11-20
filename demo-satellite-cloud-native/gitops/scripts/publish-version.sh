#!/bin/bash
# Build a new demo-app RPM and publish new content view versions, WITHOUT
# promoting anything. In the GitOps flow publishing is the "build" step;
# promotion only happens through releases.yml.
#
# (demo c2 publishes AND promotes to Dev. With the GitOps layer active,
#  satellite-config would move Dev back to what releases.yml declares on its
#  next sync, so use this script instead of c2 for the GitOps act.)
#
# Usage: gitops/scripts/publish-version.sh APP_VERSION     e.g. 3.0
#        APP_VERSION must be higher than what the hosts have installed.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

VER="${1:-}"
[[ "${VER}" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { sed -n '2,12p' "$0"; exit 1; }

# build_and_upload_rpm lives in demo-scenarios.sh; sourcing only defines functions.
# shellcheck disable=SC1091
DEMO_ENV_FILE="${DEMO_ENV_PATH}" source "${DEMO_ROOT}/scripts/demo-scenarios.sh"

# A second upload of the same version adds a duplicate package (same name and
# version, different checksum). Refuse, and say which version is next.
HAVE=$(sat_hammer "--csv --no-headers package list --repository demo-app-rpms --product Demo-App --organization Demo_Org --fields Filename" 2>/dev/null \
  | tr -d '\r' | sed -nE 's/^demo-app-([0-9.]+)-.*/\1/p' | sort -t. -k1,1n -k2,2n -k3,3n)
if grep -qx "${VER}" <<<"${HAVE}"; then
  NEXT_MAJOR=$(( $(tail -1 <<<"${HAVE}" | cut -d. -f1) + 1 ))
  die "demo-app ${VER} already exists in Satellite; use a new version, e.g. ${NEXT_MAJOR}.0 (reset.sh prints it)"
fi

log "Building demo-app ${VER} and uploading it to Demo-App/demo-app-rpms"
build_and_upload_rpm "demo-app" "${VER}" "Demo Application"

log "Publishing Demo-App-CV"
sat_hammer "content-view publish --name Demo-App-CV --organization Demo_Org" | tail -2
log "Publishing RHEL9-FullStack (composite picks the latest component versions)"
sat_hammer "content-view publish --name RHEL9-FullStack --organization Demo_Org" | tail -2

NEW=$(sat_hammer '--csv --no-headers content-view version list --content-view RHEL9-FullStack --organization Demo_Org --order "version DESC" --fields Version' 2>/dev/null | head -1 | tr -d '\r')
cat <<EOF

New RHEL9-FullStack version: ${NEW:-?} (contains demo-app ${VER}); it is in Library only.
Promote it through Git:
  gitops/scripts/release.sh promote dev          (defaults to ${NEW:-the newest version})
EOF
