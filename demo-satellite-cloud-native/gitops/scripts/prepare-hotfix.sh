#!/bin/bash
# One-time preparation for the incremental-update act: put a security erratum
# for demo-app into Satellite, so a single fix can be pushed into Prod live.
#
# Usage: gitops/scripts/prepare-hotfix.sh [BASE_VERSION] [ERRATUM_ID]
#        BASE_VERSION = the demo-app version Prod runs (default: read from lc-prod)
#        ERRATUM_ID   default DEMO-SA-2026:0002   -> package demo-app-<BASE>.1
#
# Why not a RHEL erratum live: an incremental update of the RHEL content view
# regenerates BaseOS + AppStream metadata, which takes as long as a publish
# (40+ min on a lab Satellite). Demo-App-CV is tiny, so the same mechanism
# finishes in about a minute. The real RHSAs stay visible in the Satellite UI.
#
# What it does:
#   1. Builds demo-app-<BASE>.1 on the Satellite (native el9 rpmbuild, the
#      shared build_and_upload_rpm spec: CLI + web page).
#   2. Generates repodata + updateinfo.xml (erratum type security, severity
#      Important) in a local Fedora container with createrepo_c.
#   3. Publishes the repo at http://SAT_FQDN/pub/demo-hotfix/.
#   4. Gives the existing Demo-App/demo-app-rpms repository that URL with
#      mirroring policy "additive" and syncs it: uploaded packages stay, the
#      hotfix package and its erratum are added to Library.
# Published content view versions do not contain the erratum until an
# incremental update copies it in (gitops/scripts/hotfix.sh).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd podman sshpass

BASE="${1:-}"
if [ -z "${BASE}" ]; then
  BASE=$(run_on_vm lc-prod "rpm -q --qf %{VERSION} demo-app" 2>/dev/null | tr -d '\r' | tail -1)
  [[ "${BASE}" =~ ^[0-9.]+$ ]] || die "could not read demo-app on lc-prod; pass BASE_VERSION"
  log "lc-prod runs demo-app ${BASE}"
fi
ERRATUM="${2:-DEMO-SA-2026:0002}"
HF="${BASE}.1"
PUB=/var/www/html/pub/demo-hotfix
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
SCP=(sshpass -p "${DEMO_PASSWORD}" scp ${SSH_OPTS} -o ProxyCommand="virtctl port-forward --stdio vmi/satellite.${NAMESPACE} 22")

log "Building demo-app-${HF} on the Satellite (same spec as every demo-app build, web page included)"
# build_and_upload_rpm lives in demo-scenarios.sh; sourcing only defines functions.
# shellcheck disable=SC1091
DEMO_ENV_FILE="${DEMO_ENV_PATH}" source "${DEMO_ROOT}/scripts/demo-scenarios.sh"
build_and_upload_rpm demo-app "${HF}" "Demo Application - security fix ${ERRATUM}" "" "" "${PUB}/Packages" | grep -E '^Built' \
  || die "rpmbuild failed"
run_on_vm satellite "sudo cp ${PUB}/Packages/demo-app-${HF}-1.el9.noarch.rpm /tmp/ && sudo chmod 644 /tmp/demo-app-${HF}-1.el9.noarch.rpm"
mkdir -p "${WORK}/repo/Packages"
"${SCP[@]}" "cloud-user@localhost:/tmp/demo-app-${HF}-1.el9.noarch.rpm" "${WORK}/repo/Packages/"

log "Writing updateinfo.xml (${ERRATUM}, security, Important)"
NOW=$(date -u '+%Y-%m-%d %H:%M:%S')
cat > "${WORK}/updateinfo.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<updates>
  <update from="demo@example.com" status="final" type="security" version="1">
    <id>${ERRATUM}</id>
    <title>Important: demo-app security update</title>
    <severity>Important</severity>
    <release>Demo</release>
    <issued date="${NOW}"/>
    <updated date="${NOW}"/>
    <rights>Demo content</rights>
    <summary>An update for demo-app that fixes one security issue.</summary>
    <description>demo-app ${HF} fixes a (fictional) input validation flaw in demo-app ${BASE}.
Shipped as a single hotfix: apply it with an incremental content view update.</description>
    <references>
      <reference href="https://example.com/${ERRATUM}" id="${ERRATUM}" title="${ERRATUM}" type="self"/>
    </references>
    <pkglist>
      <collection short="demo-app">
        <name>demo-app</name>
        <package name="demo-app" version="${HF}" release="1.el9" epoch="0" arch="noarch" src="demo-app-${HF}-1.el9.src.rpm">
          <filename>demo-app-${HF}-1.el9.noarch.rpm</filename>
        </package>
      </collection>
    </pkglist>
  </update>
</updates>
EOF

log "createrepo_c + modifyrepo_c (Fedora container)"
podman run --rm -v "${WORK}:/w:Z" registry.fedoraproject.org/fedora:latest bash -c \
  'dnf -y -q install createrepo_c >/dev/null 2>&1 && createrepo_c -q /w/repo && modifyrepo_c --mdtype=updateinfo /w/updateinfo.xml /w/repo/repodata >/dev/null' \
  || die "createrepo_c in the container failed"

log "Publishing http://${SAT_FQDN}/pub/demo-hotfix/"
tar -C "${WORK}/repo" -czf "${WORK}/repodata.tgz" repodata
"${SCP[@]}" "${WORK}/repodata.tgz" cloud-user@localhost:/tmp/demo-hotfix-repodata.tgz
run_on_vm satellite "sudo bash -c 'rm -rf ${PUB}/repodata && tar -C ${PUB} -xzf /tmp/demo-hotfix-repodata.tgz && chmod -R a+rX ${PUB} && restorecon -R ${PUB} && rm -f /tmp/demo-hotfix-repodata.tgz /tmp/demo-app-${HF}-1.el9.noarch.rpm'"

log "demo-app-rpms: URL + mirroring policy additive, sync"
sat_hammer "repository update --name demo-app-rpms --product Demo-App --organization Demo_Org --url http://${SAT_FQDN}/pub/demo-hotfix/ --mirroring-policy additive --download-policy immediate" >/dev/null
sat_hammer "repository synchronize --name demo-app-rpms --product Demo-App --organization Demo_Org" | tail -1
sat_hammer "erratum info --id ${ERRATUM} --organization Demo_Org --fields Title,Type,Severity,Packages" \
  || die "erratum ${ERRATUM} not found after the sync"
# Published versions must not carry the hotfix: it reaches an environment only
# through the incremental update (filters do not apply to incremental updates).
# The exclude filter lists every DEMO-SA-* erratum in the repository.
FLT=Hotfixes-via-incremental-update
if ! sat_hammer "--csv --no-headers content-view filter list --content-view Demo-App-CV --organization Demo_Org --fields Name" 2>/dev/null | grep -qx "${FLT}"; then
  log "Demo-App-CV: exclude filter ${FLT}"
  sat_hammer "content-view filter create --name ${FLT} --content-view Demo-App-CV --organization Demo_Org --type erratum --inclusion false --description Hotfix\\ errata\\ reach\\ an\\ environment\\ only\\ by\\ incremental\\ update" >/dev/null
fi
HAVE=$(sat_hammer "--csv --no-headers content-view filter rule list --content-view Demo-App-CV --content-view-filter ${FLT} --organization Demo_Org --fields \"Errata ID\"" 2>/dev/null | tr -d '\r' || true)
for e in $(sat_hammer "--csv --no-headers erratum list --repository demo-app-rpms --product Demo-App --organization Demo_Org --fields \"Errata ID\"" | tr -d '\r' | grep '^DEMO-SA-'); do
  grep -qx "${e}" <<<"${HAVE}" && continue
  sat_hammer "content-view filter rule create --content-view Demo-App-CV --content-view-filter ${FLT} --organization Demo_Org --errata-id ${e}" >/dev/null
  log "  excluded ${e} from published Demo-App-CV versions"
done

cat <<EOF

Ready. Live step (Demo 1, incremental update into Prod):
  gitops/scripts/hotfix.sh ${ERRATUM} prod
EOF
