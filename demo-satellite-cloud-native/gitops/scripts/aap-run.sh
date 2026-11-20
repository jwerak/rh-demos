#!/bin/bash
# Launch an AAP job template by name from the terminal and wait for it.
#
# Usage: gitops/scripts/aap-run.sh "TEMPLATE NAME" [key=value ...]
#   e.g. gitops/scripts/aap-run.sh "GitOps · Promote release" lifecycle_env=dev auto_merge=no
#        gitops/scripts/aap-run.sh "HOST · Update package" host_search="name ~ lc-dev"
# key=value pairs become extra vars (survey answers). Prints the job's
# debug messages and exits non-zero when the job fails.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

NAME="${1:-}"; shift || true
[ -n "${NAME}" ] || { sed -n '2,9p' "$0"; exit 1; }
VARS=$(python3 -I -c 'import json,sys; print(json.dumps(dict(a.split("=",1) for a in sys.argv[1:])))' "$@")
TID=$(aap_api "/job_templates/?name=$(python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${NAME}")" \
  | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["results"]; print(r[0]["id"] if r else "")')
[ -n "${TID}" ] || die "job template not found: ${NAME}"
# The API does not apply survey defaults (only the UI does): fill them in.
VARS=$(aap_api "/job_templates/${TID}/survey_spec/" | python3 -I -c '
import json, sys
given = json.loads(sys.argv[1])
spec = json.load(sys.stdin).get("spec", [])
for q in spec:
    if q["variable"] not in given and q.get("default") not in (None, ""):
        given[q["variable"]] = q["default"]
print(json.dumps(given))' "${VARS}")
JID=$(curl_aap -sSk --max-time 60 -H 'Content-Type: application/json' -X POST \
  -d "{\"extra_vars\": ${VARS}}" "$(aap_url)/api/controller/v2/job_templates/${TID}/launch/" \
  | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("job") or d)')
[[ "${JID}" =~ ^[0-9]+$ ]] || die "launch failed: ${JID}"
log "${NAME}: job ${JID} ($(aap_url)/execution/jobs/playbook/${JID}/output)"
T0=$(date +%s)
# Wait up to AAP_RUN_TIMEOUT seconds (default 900); a transient API hiccup is retried.
ST=unknown
while [ $(( $(date +%s) - T0 )) -lt "${AAP_RUN_TIMEOUT:-900}" ]; do
  ST=$(aap_api "/jobs/${JID}/" 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null || echo unknown)
  case "${ST}" in successful|failed|error|canceled) break ;; esac
  sleep 3
done
aap_api "/jobs/${JID}/job_events/?event__in=runner_on_ok,runner_item_on_ok&order_by=counter&page_size=200" \
  | python3 -I -c '
import json, sys
for e in json.load(sys.stdin)["results"]:
    d = e.get("event_data") or {}
    if d.get("task_action") not in ("debug", "ansible.builtin.debug"):
        continue
    m = d.get("res", {}).get("msg")
    if m:
        for line in (m if isinstance(m, list) else [m]):
            print("  " + str(line))'
log "job ${JID}: ${ST} in $(( $(date +%s) - T0 )) s"
[ "${ST}" = successful ]
