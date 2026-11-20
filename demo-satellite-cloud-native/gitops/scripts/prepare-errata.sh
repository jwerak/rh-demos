#!/bin/bash
# Prepare real RHEL errata for the incremental-update act (one-time, before
# the GitOps bootstrap or before a rehearsal).
#
# Usage: gitops/scripts/prepare-errata.sh [CUTOFF_DATE]      e.g. 2026-10-31
#
# Needs: subscription manifest uploaded, RHEL 9 BaseOS + AppStream synced
# (scripts/upload-manifest.sh, part of deploy.sh), demo c1 run (RHEL9-Lifecycle
# carries those repos, lc-dev/qa/prod exist).
#
# What it does:
#   1. Errata filter "Errata-Cutoff" on RHEL9-Lifecycle: include errata issued
#      up to CUTOFF_DATE plus every package without errata. Default cutoff: the
#      newest package build date on lc-prod, i.e. roughly the cloud image date,
#      so the content view serves nothing newer than what the hosts already run.
#   2. Publishes RHEL9-Lifecycle and the composite RHEL9-FullStack.
#   3. Before the GitOps layer exists (no satellite-config application) it
#      promotes the new composite version to Dev, QA and Prod with hammer;
#      afterwards it prints the release.sh commands instead.
#   4. Lists errata that apply to lc-prod but are NOT installable there:
#      candidates for the incremental update (pick a small RHSA/RHBA).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

ORG=Demo_Org
CV=RHEL9-Lifecycle
FILTER=Errata-Cutoff
CUTOFF="${1:-}"

if [ -z "${CUTOFF}" ]; then
  # INSTALLTIME of basesystem = when the cloud image was built. (Newest
  # BUILDTIME would be today: demo-app is built on the Satellite.)
  CUTOFF=$(run_on_vm lc-prod "rpm -q --qf '%{INSTALLTIME}' basesystem" 2>/dev/null | tr -d '\r' | tail -1)
  [[ "${CUTOFF}" =~ ^[0-9]+$ ]] || die "could not read the image date on lc-prod; pass CUTOFF_DATE"
  CUTOFF=$(date -u -d "@${CUTOFF}" +%F)
  log "Cutoff = lc-prod cloud image build date: ${CUTOFF}"
fi
[[ "${CUTOFF}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "CUTOFF_DATE must be YYYY-MM-DD"

REPOS=$(sat_hammer "--csv --no-headers content-view info --name ${CV} --organization ${ORG} --fields Yum\ repositories/name" 2>/dev/null | tr -d '\r' || true)
grep -q 'BaseOS' <<<"${REPOS}" || die "${CV} has no RHEL BaseOS repository (manifest uploaded? c1 run after the sync?)"

log "Waiting for running repository syncs to finish"
for _ in $(seq 1 120); do
  n=$(sat_hammer '--csv --no-headers task list --search "label = Actions::Katello::Repository::Sync and state = running"' 2>/dev/null | grep -c . || true)
  [ "${n:-0}" -eq 0 ] && break
  sleep 30
done

if sat_hammer "--csv --no-headers content-view filter list --content-view ${CV} --organization ${ORG} --fields Name" 2>/dev/null | grep -qx "${FILTER}"; then
  log "Filter ${FILTER} exists; updating its end date to ${CUTOFF}"
  RULE=$(sat_hammer "--csv --no-headers content-view filter rule list --content-view ${CV} --content-view-filter ${FILTER} --organization ${ORG} --fields Id" | tr -d '\r' | head -1)
  sat_hammer "content-view filter rule update --id ${RULE} --content-view ${CV} --content-view-filter ${FILTER} --organization ${ORG} --end-date ${CUTOFF}" >/dev/null
else
  log "Creating filter ${FILTER} (errata issued until ${CUTOFF} + packages without errata)"
  sat_hammer "content-view filter create --name ${FILTER} --content-view ${CV} --organization ${ORG} --type erratum_date --inclusion true --description Errata\ until\ ${CUTOFF},\ newer\ fixes\ by\ incremental\ update" >/dev/null
  sat_hammer "content-view filter rule create --content-view ${CV} --content-view-filter ${FILTER} --organization ${ORG} --date-type issued --end-date ${CUTOFF} --types security,bugfix,enhancement" >/dev/null
fi
# An errata inclusion filter alone would drop every package that belongs to
# no erratum (most of the base OS). Katello does not allow original_packages
# on errata filters: that needs its own rpm inclusion filter.
if ! sat_hammer "--csv --no-headers content-view filter list --content-view ${CV} --organization ${ORG} --fields Name" 2>/dev/null | grep -qx "${FILTER}-NoErrata"; then
  log "Creating filter ${FILTER}-NoErrata (all packages without errata)"
  sat_hammer "content-view filter create --name ${FILTER}-NoErrata --content-view ${CV} --organization ${ORG} --type rpm --inclusion true --original-packages true --description Packages\ that\ belong\ to\ no\ erratum" >/dev/null
fi

log "Publishing ${CV} (several minutes for BaseOS + AppStream)"
t0=$(date +%s)
sat_hammer "content-view publish --name ${CV} --organization ${ORG} --description Errata\ until\ ${CUTOFF}" | tail -1
log "Publishing RHEL9-FullStack"
sat_hammer "content-view publish --name RHEL9-FullStack --organization ${ORG} --description RHEL\ errata\ until\ ${CUTOFF}" | tail -1
NEW=$(satellite_latest_version)
log "RHEL9-FullStack ${NEW} published in $(( $(date +%s) - t0 )) s"

if oc get applications.argoproj.io satellite-config -n openshift-gitops >/dev/null 2>&1; then
  cat <<EOF
GitOps layer is active: promote through Git
  gitops/scripts/release.sh promote dev ${NEW} --merge
  gitops/scripts/release.sh promote qa  --merge
  gitops/scripts/release.sh promote prod --merge
EOF
else
  for env in Dev QA Prod; do
    log "Promoting RHEL9-FullStack ${NEW} to ${env}"
    sat_hammer "content-view version promote --content-view RHEL9-FullStack --version ${NEW} --to-lifecycle-environment ${env} --organization ${ORG} --force" | tail -1
  done
fi

HOST=$(sat_hammer '--csv --no-headers host list --organization Demo_Org --search "name ~ lc-prod" --fields Name' 2>/dev/null | tr -d '\r' | head -1)
if [ -n "${HOST}" ]; then
  log "Errata that apply to ${HOST} but are not installable (incremental-update candidates):"
  sat_hammer "--csv erratum list --organization ${ORG} --host ${HOST} --errata-restrict-applicable true --errata-restrict-installable false --order issued\ DESC --per-page 40 --fields Errata\ ID,Type,Issued,Title" \
    | tr -d '\r' | sed 's/^/  /'
  log "Installable on ${HOST} now (should be empty or short):"
  sat_hammer "--csv --no-headers erratum list --organization ${ORG} --host ${HOST} --errata-restrict-installable true --fields Errata\ ID" | tr -d '\r' | sed 's/^/  /'
fi
