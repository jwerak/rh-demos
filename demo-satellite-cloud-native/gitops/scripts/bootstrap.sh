#!/bin/bash
# Bring up the GitOps layer on top of a running OpenShift-profile Satellite lab.
#
# Usage: DEMO_ENV_FILE=.env.ocp gitops/scripts/bootstrap.sh [phase ...]
#   phases (default "all", in this order):
#     check     oc login, namespace, Satellite VM, rhsm-credentials, tools
#     operator  OpenShift GitOps operator, wait for the Argo CD instance
#     gitea     Gitea deployment, admin user, API token, empty repo
#     secrets   fleet-cloudinit-<env> + satellite-cac-credentials (never in Git)
#     runner    build the Satellite-as-code runner image in the cluster
#     rbac      let Argo CD manage the demo namespace
#     seed      push gitops/repo to Gitea (only if the repo is empty; --force reseeds)
#     apps      Argo CD applications rhel-fleet + satellite-config
#     webhook   Gitea -> Argo CD push webhook, faster reconciliation
#     aap       AAP operator + instance (gateway, controller), admin password,
#               subscription from AAP_MANIFEST if set. Independent of the
#               Satellite: can run in parallel with scripts/deploy.sh
#     aapconfig AAP config as code: credentials, GitOps EE, job templates
#               (needs gitea, seed, runner, aap)
#     info      print URLs and credentials hints
#
# AAP_ENABLED=false skips aap/aapconfig in "all".
# Idempotent: every phase can be re-run.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

FORCE_SEED=false
PHASES=()
for a in "$@"; do
  case "$a" in
    --force) FORCE_SEED=true ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) PHASES+=("$a") ;;
  esac
done
[ ${#PHASES[@]} -eq 0 ] && PHASES=(all)

phase_check() {
  log "Pre-flight"
  require_cmd oc curl git sshpass virtctl
  oc whoami >/dev/null 2>&1 || die "not logged in to OpenShift (oc login ...)"
  oc get ns "${NAMESPACE}" >/dev/null 2>&1 || die "namespace ${NAMESPACE} missing: run scripts/deploy.sh first"
  oc get vm satellite -n "${NAMESPACE}" >/dev/null 2>&1 || die "Satellite VM missing in ${NAMESPACE}"
  oc get secret rhsm-credentials -n "${NAMESPACE}" >/dev/null 2>&1 \
    || die "Secret rhsm-credentials missing: run scripts/create-rhsm-secret.sh"
  oc get datasource rhel9 -n openshift-virtualization-os-images >/dev/null 2>&1 \
    || warn "DataSource rhel9 not found in openshift-virtualization-os-images"
  log "  cluster: $(oc whoami --show-server)  user: $(oc whoami)"
}

phase_operator() {
  log "OpenShift GitOps operator"
  # Reuse an operator that is already installed (any namespace, any channel):
  # a second Subscription for the same package makes OLM conflict and could
  # upgrade an Argo CD instance that other workloads on the cluster share.
  local existing
  existing=$(oc get subscriptions.operators.coreos.com -A \
    -o jsonpath='{range .items[?(@.spec.name=="openshift-gitops-operator")]}{.metadata.namespace}/{.spec.channel}{"\n"}{end}' 2>/dev/null | head -1)
  if [ -n "${existing}" ]; then
    log "  already installed (${existing}); not subscribing again"
  else
    oc apply -f "${GITOPS_DIR}/bootstrap/gitops-operator.yaml"
  fi
  log "  waiting for the Argo CD instance in openshift-gitops (up to 10 min)"
  local i
  for i in $(seq 1 60); do
    if oc get deploy openshift-gitops-server -n openshift-gitops >/dev/null 2>&1; then
      oc rollout status deploy/openshift-gitops-server -n openshift-gitops --timeout=300s && break
    fi
    sleep 10
  done
  oc get deploy openshift-gitops-server -n openshift-gitops >/dev/null 2>&1 \
    || die "Argo CD did not appear (oc get csv -n openshift-gitops-operator)"
  # Poll Git every 60 s instead of 180 s; the webhook phase makes it near-instant.
  # The operator renders ARGOCD_RECONCILIATION_TIMEOUT from spec.controller.appSync;
  # extraConfig.timeout.reconciliation is ignored. Only shortens, never lengthens.
  local cur
  cur=$(oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.controller.appSync}' 2>/dev/null || true)
  if [ "${cur}" != "60s" ]; then
    oc patch argocd openshift-gitops -n openshift-gitops --type merge \
      -p '{"spec":{"controller":{"appSync":"60s"}}}' >/dev/null 2>&1 \
      && log "  Argo CD polls Git every 60 s (spec.controller.appSync)" \
      || warn "could not shorten Argo CD reconciliation timeout (use Refresh in the UI)"
  fi
}

phase_gitea() {
  log "Gitea"
  oc apply -f "${GITOPS_DIR}/bootstrap/gitea.yaml"
  oc adm policy add-scc-to-user anyuid -z default -n "${GITEA_NS}" >/dev/null
  local host
  for _ in $(seq 1 30); do host="$(gitea_host)"; [ -n "${host}" ] && break; sleep 2; done
  [ -n "${host}" ] || die "Gitea route has no host"
  oc set env deploy/gitea -n "${GITEA_NS}" \
    "GITEA__server__DOMAIN=${host}" "GITEA__server__ROOT_URL=https://${host}/" >/dev/null
  oc rollout status deploy/gitea -n "${GITEA_NS}" --timeout=600s

  log "  admin user ${GITEA_USER}"
  local i
  for i in $(seq 1 30); do
    oc exec -n "${GITEA_NS}" deploy/gitea -- su -s /bin/sh git -c "gitea admin user list" >/dev/null 2>&1 && break
    sleep 5
  done
  if ! oc exec -n "${GITEA_NS}" deploy/gitea -- su -s /bin/sh git -c "gitea admin user list" 2>/dev/null \
       | awk 'NR>1 {print $2}' | grep -qx "${GITEA_USER}"; then
    oc exec -n "${GITEA_NS}" deploy/gitea -- su -s /bin/sh git -c \
      "gitea admin user create --admin --username ${GITEA_USER} --password '${GITEA_PASSWORD}' --email ${GITEA_USER}@example.com --must-change-password=false" \
      >/dev/null
  fi

  local url="https://${host}"
  if [ -s "${GITEA_TOKEN_FILE}" ] && curl -sSkf -H "Authorization: token $(cat "${GITEA_TOKEN_FILE}")" \
       "${url}/api/v1/user" >/dev/null 2>&1; then
    log "  API token: reusing ${GITEA_TOKEN_FILE}"
  else
    log "  API token: creating"
    mkdir -p "${CACHE_DIR}"
    local tok
    tok=$(curl -sSkf -u "${GITEA_USER}:${GITEA_PASSWORD}" -H 'Content-Type: application/json' \
      -d "{\"name\":\"demo-$(date +%s)\",\"scopes\":[\"write:repository\",\"write:issue\",\"write:user\"]}" \
      "${url}/api/v1/users/${GITEA_USER}/tokens" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["sha1"])')
    [ -n "${tok}" ] || die "token creation failed"
    ( umask 077; printf '%s' "${tok}" > "${GITEA_TOKEN_FILE}" )
  fi

  if gitea_api GET "/repos/${GITEA_USER}/${GITEA_REPO}" >/dev/null 2>&1; then
    log "  repo ${GITEA_USER}/${GITEA_REPO} exists"
  else
    log "  repo ${GITEA_USER}/${GITEA_REPO}: creating (public, no secrets inside)"
    gitea_api POST "/user/repos" \
      "{\"name\":\"${GITEA_REPO}\",\"private\":false,\"default_branch\":\"main\",\"auto_init\":false,\"description\":\"RHEL fleet + Satellite configuration (GitOps demo)\"}" \
      >/dev/null
  fi
}

phase_secrets() {
  log "Cluster-only secrets"
  local ipa_domain ipa_realm enroll_idm=false
  ipa_domain="${IDM_FQDN#*.}"
  [ -n "${IDM_FQDN:-}" ] || ipa_domain="${SAT_FQDN#*.}"
  ipa_realm="$(echo "${ipa_domain}" | tr '[:lower:]' '[:upper:]')"
  if [ -n "${IDM_FQDN:-}" ] && [ "${DEPLOY_IDM:-true}" != "false" ] \
     && oc get vm idm -n "${NAMESPACE}" >/dev/null 2>&1; then
    enroll_idm=true
  fi
  local env
  for env in ${FLEET_ENVS}; do
    sed -e "s|__FLEET_ENV__|${env}|g" \
        -e "s|__DEMO_PASSWORD__|${DEMO_PASSWORD}|g" \
        -e "s|__IDM_FQDN__|${IDM_FQDN:-}|g" \
        -e "s|__SAT_FQDN__|${SAT_FQDN}|g" \
        -e "s|__IPA_DOMAIN__|${ipa_domain}|g" \
        -e "s|__IPA_REALM__|${ipa_realm}|g" \
        -e "s|__ENROLL_IDM__|${enroll_idm}|g" \
        "${GITOPS_DIR}/bootstrap/fleet-cloudinit-secret.yaml.tpl" | oc apply -f - >/dev/null
    log "  fleet-cloudinit-${env} (IdM enrollment: ${enroll_idm})"
  done
  oc create secret generic satellite-cac-credentials -n "${NAMESPACE}" \
    --from-literal=FOREMAN_SERVER_URL="${SATELLITE_API_URL}" \
    --from-literal=FOREMAN_USERNAME=admin \
    --from-literal=FOREMAN_PASSWORD="${DEMO_PASSWORD}" \
    --from-literal=FOREMAN_VALIDATE_CERTS=false \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  log "  satellite-cac-credentials -> ${SATELLITE_API_URL}"
  # Empty placeholder so fleet VMs can mount disk "satreg" before the first
  # satellite-cac Job has run; the Job fills it in (server-side apply, force).
  if ! oc get secret satellite-registration -n "${NAMESPACE}" >/dev/null 2>&1; then
    oc create secret generic satellite-registration -n "${NAMESPACE}" >/dev/null
    log "  satellite-registration placeholder (filled by the satellite-cac Job)"
  fi
}

phase_runner() {
  log "Runner image (in-cluster build)"
  if oc get bc satellite-cac-runner -n "${NAMESPACE}" >/dev/null 2>&1; then
    # The BuildConfig stores the Dockerfile inline: refresh it from the
    # Containerfile, otherwise start-build rebuilds the old one. Also drop
    # dockerStrategy.from: `oc new-build` pins the first FROM image there and
    # it silently overrides the FROM line of every later Dockerfile.
    oc patch bc satellite-cac-runner -n "${NAMESPACE}" --type merge -p \
      "$(python3 -I -c 'import json,sys; print(json.dumps({"spec":{"source":{"dockerfile":open(sys.argv[1]).read()},"strategy":{"dockerStrategy":{"from":None}}}}))' "${GITOPS_DIR}/runner/Containerfile")" >/dev/null
    oc start-build satellite-cac-runner -n "${NAMESPACE}" --follow
  else
    oc new-build -n "${NAMESPACE}" --name satellite-cac-runner --strategy docker \
      --to satellite-cac-runner:latest -D - < "${GITOPS_DIR}/runner/Containerfile"
    # see above: never let the BuildConfig pin the base image
    oc patch bc satellite-cac-runner -n "${NAMESPACE}" --type merge \
      -p '{"spec":{"strategy":{"dockerStrategy":{"from":null}}}}' >/dev/null 2>&1 || true
    sleep 5
    oc logs -f bc/satellite-cac-runner -n "${NAMESPACE}" || true
  fi
  # Without the image the Job pod sits in ImagePullBackOff and the sync hangs
  # until activeDeadlineSeconds, so this is fatal.
  oc get istag satellite-cac-runner:latest -n "${NAMESPACE}" >/dev/null 2>&1 \
    || die "runner image missing (oc get builds -n ${NAMESPACE}); re-run 'bootstrap.sh runner'"
}

phase_rbac() {
  log "Argo CD access to ${NAMESPACE}"
  oc label namespace "${NAMESPACE}" argocd.argoproj.io/managed-by=openshift-gitops --overwrite >/dev/null
  oc apply -f "${GITOPS_DIR}/bootstrap/argocd-rbac.yaml" >/dev/null
}

# releases.yml is seeded with the versions Satellite serves now (lib.sh
# satellite_releases), so the first sync is a no-op instead of a surprise promotion.
phase_seed() {
  log "Seed Gitea repo ${GITEA_USER}/${GITEA_REPO}"
  local empty
  empty=$(gitea_api GET "/repos/${GITEA_USER}/${GITEA_REPO}" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["empty"])')
  if [ "${empty}" != "True" ] && [ "${FORCE_SEED}" != "true" ]; then
    log "  repo already has commits; leaving it (use: bootstrap.sh seed --force)"
    return 0
  fi
  local work
  work=$(mktemp -d)
  cp -a "${GITOPS_DIR}/repo/." "${work}/"
  local rel
  if rel=$(satellite_releases); then
    log "  releases.yml from Satellite: ${rel}"
    local kv k v
    for kv in ${rel}; do
      k="${kv%%=*}"; v="${kv#*=}"
      sed -i -E "s|^(  ${k}: ).*|\\1\"${v}\"|" "${work}/satellite/releases.yml"
    done
  else
    warn "could not read RHEL9-FullStack versions (has demo c1 run?); releases.yml keeps 1.0"
  fi
  local push_opts=(-q)
  [ "${FORCE_SEED}" = true ] && push_opts+=(--force)
  (
    cd "${work}"
    git init -q -b main
    git add -A
    git -c user.name="GitOps Demo" -c user.email="${GITEA_USER}@example.com" \
      commit -q -m "Initial fleet and Satellite configuration"
    GIT_SSL_NO_VERIFY=true git push "${push_opts[@]}" \
      "https://${GITEA_USER}:$(gitea_token)@$(gitea_host)/${GITEA_USER}/${GITEA_REPO}.git" main
  )
  # Start state for gitops/scripts/reset.sh
  mkdir -p "${CACHE_DIR}"
  sed -nE 's/^  (Dev|QA|Prod): "?([0-9.]+)"?.*/\1=\2/p' "${work}/satellite/releases.yml" | paste -sd' ' > "${CACHE_DIR}/gitops-baseline"
  rm -rf "${work}"
  log "  pushed; reset baseline: $(cat "${CACHE_DIR}/gitops-baseline")"
}

# Argo CD uses the Gitea *route* URL, not the service URL: its webhook handler
# matches the push payload's repository.html_url (Gitea ROOT_URL = route host)
# against each application's repoURL, so with the service URL every webhook is
# silently ignored and changes wait for polling.
phase_apps() {
  local repo_url
  repo_url="$(gitea_url)/${GITEA_USER}/${GITEA_REPO}.git"
  log "Argo CD applications (repo ${repo_url})"
  # Repository entry: tolerate a self-signed router certificate on lab clusters.
  oc create secret generic "repo-${GITEA_REPO}" -n openshift-gitops \
    --from-literal=type=git --from-literal=url="${repo_url}" --from-literal=insecure=true \
    --dry-run=client -o yaml \
    | oc label --local -f - argocd.argoproj.io/secret-type=repository demo=satellite-cloud-native -o yaml \
    | oc apply -f - >/dev/null
  sed -e "s|__REPO_URL__|${repo_url}|g" "${GITOPS_DIR}/bootstrap/applications.yaml" \
    | python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
if sys.argv[1] != "argo":   # Satellite as code runs in AAP (EDA), Argo CD keeps the VMs
    docs = [d for d in docs if d["metadata"]["name"] != "satellite-config"]
print(yaml.safe_dump_all(docs))' "${SATELLITE_EXECUTOR}" | oc apply -f -
  if [ "${SATELLITE_EXECUTOR}" != "argo" ] \
     && oc get applications.argoproj.io satellite-config -n openshift-gitops >/dev/null 2>&1; then
    # No finalizer on the app: the ConfigMap/Job/RBAC stay, only Argo CD stops syncing.
    oc delete applications.argoproj.io satellite-config -n openshift-gitops >/dev/null
    log "  satellite-config removed from Argo CD (SATELLITE_EXECUTOR=aap: EDA + AAP apply satellite/)"
  fi
  # Executor switch: enable/disable the EDA side to match (needs AAP up).
  if [ "${AAP_ENABLED:-true}" = "true" ] && [ -s "${AAP_PASSWORD_FILE}" ]; then
    satellite_executor_wiring
  fi
}

phase_webhook() {
  log "Gitea -> Argo CD webhook"
  local target="https://openshift-gitops-server.openshift-gitops.svc.cluster.local/api/webhook"
  if gitea_api GET "/repos/${GITEA_USER}/${GITEA_REPO}/hooks" | grep -q "${target}"; then
    log "  exists"
    return 0
  fi
  gitea_api POST "/repos/${GITEA_USER}/${GITEA_REPO}/hooks" \
    "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"${target}\",\"content_type\":\"json\"}}" \
    >/dev/null && log "  created -> ${target}" || warn "webhook not created; Argo CD polls every 60 s (or press Refresh)"
}

# AAP on the same cluster. Independent of the Satellite VM, so it can run
# in parallel with scripts/deploy.sh: `bootstrap.sh aap` right after oc login.
phase_aap() {
  log "Ansible Automation Platform operator (namespace ${AAP_NS})"
  oc apply -f "${GITOPS_DIR}/bootstrap/aap-operator.yaml"
  log "  waiting for the operator CSV (up to 15 min)"
  # The CSV is named aap-operator.v2.x-..., not after the package: follow the
  # Subscription's installedCSV instead of guessing the name.
  local i phase="" csv=""
  for i in $(seq 1 90); do
    csv=$(oc get subscriptions.operators.coreos.com ansible-automation-platform-operator -n "${AAP_NS}" \
      -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [ -n "${csv}" ]; then
      phase=$(oc get csv "${csv}" -n "${AAP_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      [ "${phase}" = "Succeeded" ] && break
    fi
    sleep 10
  done
  log "  operator CSV ${csv:-?}: ${phase:-not found}"
  [ "${phase}" = "Succeeded" ] || die "AAP operator not ready (oc get csv,installplan -n ${AAP_NS})"
  oc wait --for=condition=Established crd/ansibleautomationplatforms.aap.ansible.com --timeout=120s >/dev/null

  log "  AnsibleAutomationPlatform '${AAP_NAME}' (gateway + controller; hub, EDA off)"
  sed -e "s|name: aap$|name: ${AAP_NAME}|" -e "s|namespace: aap$|namespace: ${AAP_NS}|" \
    "${GITOPS_DIR}/bootstrap/aap-instance.yaml" | oc apply -f -

  log "  waiting for the platform gateway (typically 10-20 min)"
  local host="" code=""
  for i in $(seq 1 180); do
    host="$(aap_host)"
    if [ -n "${host}" ]; then
      code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${host}/api/gateway/v1/ping/" || true)
      [ "${code}" = "200" ] && break
    fi
    sleep 10
  done
  [ "${code}" = "200" ] || die "AAP gateway not answering (oc get pods -n ${AAP_NS}; oc get aap ${AAP_NAME} -n ${AAP_NS} -o yaml)"
  log "  gateway: https://${host}"
  # The gateway answers its ping long before the controller behind it is up
  # (then every /api/controller/ call is "503 no healthy upstream").
  log "  waiting for the automation controller behind the gateway"
  for i in $(seq 1 90); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${host}/api/controller/v2/ping/" || true)
    [ "${code}" = "200" ] && break
    sleep 10
  done
  [ "${code}" = "200" ] || die "controller not answering behind the gateway (oc get pods -n ${AAP_NS})"

  # EDA enabled after the first install (or on some operator versions) lacks
  # the system credential "_DEFAULT_EDA_PG_NOTIFY_CREDS"; creating any rulebook
  # activation then fails with HTTP 500 ("'NoneType' object has no attribute
  # 'id'"). create_initial_data is idempotent and adds what is missing.
  if oc get deploy "${AAP_NAME}-eda-api" -n "${AAP_NS}" >/dev/null 2>&1; then
    oc rollout status "deploy/${AAP_NAME}-eda-api" -n "${AAP_NS}" --timeout=600s >/dev/null
    oc exec -n "${AAP_NS}" "deploy/${AAP_NAME}-eda-api" -c eda-api -- aap-eda-manage create_initial_data >/dev/null 2>&1 \
      && log "  EDA initial data ensured" || warn "EDA create_initial_data failed (rulebook activations may return HTTP 500)"
  fi

  mkdir -p "${CACHE_DIR}"
  oc get secret "${AAP_NAME}-admin-password" -n "${AAP_NS}" -o jsonpath='{.data.password}' | base64 -d > "${AAP_PASSWORD_FILE}" \
    || die "Secret ${AAP_NAME}-admin-password not found in ${AAP_NS}"
  chmod 600 "${AAP_PASSWORD_FILE}"
  log "  admin password saved to ${AAP_PASSWORD_FILE}"

  aap_license
}

# Activate the subscription from a manifest ZIP if AAP_MANIFEST points to one.
# Otherwise (or on failure) the first UI login asks for a manifest or a
# Red Hat service account; that is a two-minute manual step.
aap_license() {
  local url cfg
  url="$(aap_url)"
  cfg=$(curl_aap -sk "${url}/api/controller/v2/config/" || true)
  if printf '%s' "${cfg}" | python3 -I -c 'import json,sys; li=json.load(sys.stdin).get("license_info") or {}; sys.exit(0 if li.get("valid_key") is True and li.get("license_type") not in (None, "", "open", "UNLICENSED") else 1)' 2>/dev/null; then
    log "  subscription already active"
    return 0
  fi
  if [ -z "${AAP_MANIFEST}" ] || [ ! -s "${AAP_MANIFEST}" ]; then
    warn "AAP has no subscription yet: log in at ${url} and upload a manifest or use a service account (or set AAP_MANIFEST and re-run 'bootstrap.sh aap')"
    return 0
  fi
  log "  activating subscription from ${AAP_MANIFEST}"
  local body
  body=$(mktemp)
  python3 -I -c 'import base64,json,sys; print(json.dumps({"eula_accepted": True, "manifest": base64.b64encode(open(sys.argv[1],"rb").read()).decode()}))' \
    "${AAP_MANIFEST}" > "${body}"
  if curl_aap -sk --fail-with-body -H 'Content-Type: application/json' \
       -X POST --data-binary "@${body}" "${url}/api/controller/v2/config/" >/dev/null; then
    log "  subscription activated"
  else
    warn "manifest upload failed; activate in the UI (${url}) with a manifest or a service account"
  fi
  rm -f "${body}"
}

# Load gitops/repo/aap/aap-config.yml (job template + survey) into AAP.
# Uses the locally installed infra.aap_configuration / ansible.platform /
# ansible.controller. AAP job pods run in the cluster, so the project and the
# Gitea API credential use the internal service URL (no route, no TLS).
phase_aapconfig() {
  log "AAP configuration as code (credentials, GitOps EE, job templates, EDA)"
  require_cmd ansible-playbook ansible-galaxy
  # The project syncs from Gitea; an empty repo fails with "pathspec 'main'".
  gitea_api GET "/repos/${GITEA_USER}/${GITEA_REPO}" | grep -q '"empty":false' \
    || die "Gitea repo ${GITEA_USER}/${GITEA_REPO} is empty: run 'bootstrap.sh seed' first"
  local c
  for c in infra.aap_configuration ansible.platform ansible.controller ansible.eda; do
    ansible-galaxy collection list "$c" 2>/dev/null | grep -q "^$c " \
      || die "collection $c missing (ansible-galaxy collection install $c; ansible.* need Automation Hub)"
  done
  # Identity of AAP jobs in the cluster (namespace-scoped) + EE pull rights.
  sed -e "s|system:serviceaccounts:aap$|system:serviceaccounts:${AAP_NS}|" \
    "${GITOPS_DIR}/bootstrap/aap-rbac.yaml" | oc apply -f - >/dev/null
  local k8s_token=""
  for _ in $(seq 1 30); do
    k8s_token=$(oc get secret aap-demo-token -n "${NAMESPACE}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
    [ -n "${k8s_token}" ] && break
    sleep 2
  done
  [ -n "${k8s_token}" ] || die "token for ServiceAccount aap-demo not issued"
  oc get istag satellite-cac-runner:latest -n "${NAMESPACE}" >/dev/null 2>&1 \
    || die "GitOps EE image missing: run 'bootstrap.sh runner' first"

  # AAP 2.7 has no controller token endpoint (/api/controller/v2/tokens/ is a
  # 404), and ansible.controller modules given only username/password try to
  # fetch one there. Hand them a short-lived gateway token instead.
  local tok_json tok tok_id
  tok_json=$(curl_aap -sSk --fail-with-body -H 'Content-Type: application/json' \
    -d '{"description":"bootstrap.sh aapconfig","scope":"write"}' "$(aap_url)/api/gateway/v1/tokens/") \
    || die "could not create a gateway token (is the subscription active? see 'bootstrap.sh aap')"
  tok=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["token"])' <<<"${tok_json}")
  tok_id=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"${tok_json}")
  # Extra vars file: every value as a YAML !unsafe single-quoted scalar, so a
  # password with quotes, backslashes or "{{" neither breaks YAML nor gets
  # templated. Removed (with the gateway token) even on Ctrl-C.
  local vars
  vars=$(mktemp)
  chmod 600 "${vars}"
  trap 'rm -f "${vars}"; curl_aap -sk -o /dev/null -X DELETE "$(aap_url)/api/gateway/v1/tokens/${tok_id}/" 2>/dev/null' EXIT
  AAPV_aap_hostname="$(aap_url)" AAPV_aap_username=admin AAPV_aap_password="$(aap_password)" \
  AAPV_aap_token="${tok}" AAPV_gitea_url="${GITEA_INTERNAL_URL}" AAPV_gitea_repo_url="${GITEA_REPO_URL_INTERNAL}" \
  AAPV_gitea_token="$(gitea_token)" AAPV_satellite_url="${SATELLITE_API_URL}" AAPV_satellite_password="${DEMO_PASSWORD}" \
  AAPV_k8s_host="https://kubernetes.default.svc" AAPV_k8s_token="${k8s_token}" \
  AAPV_gitops_ee_image="image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/satellite-cac-runner:latest" \
  AAPV_aap_url="$(aap_url)" AAPV_aap_admin_password="$(aap_password)" AAPV_eda_webhook_secret="$(eda_webhook_secret)" \
  python3 -I -c '
import os
for k, v in sorted(os.environ.items()):
    if k.startswith("AAPV_"):
        print("%s: !unsafe \x27%s\x27" % (k[5:], v.replace("\x27", "\x27\x27")))
print("aap_validate_certs: false")' > "${vars}"
  # EDA refuses to update a running activation ("Activation is not in disabled
  # mode and in stopped status"): keep an existing one, unless asked to recreate.
  local act_id
  act_id=$(curl_aap -sk "$(aap_url)/api/eda/v1/activations/?name=satellite_as_code" \
    | python3 -I -c 'import json,sys; r=json.load(sys.stdin).get("results",[]); print(r[0]["id"] if r else "")' 2>/dev/null || true)
  if [ -n "${act_id}" ]; then
    if [ "${AAP_RECREATE_ACTIVATION:-false}" = "true" ]; then
      curl_aap -sk -o /dev/null -X DELETE "$(aap_url)/api/eda/v1/activations/${act_id}/"
      log "  rulebook activation satellite_as_code deleted (AAP_RECREATE_ACTIVATION=true)"
      # The new activation must see the current rulebook: re-import the project.
      local proj_id
      proj_id=$(curl_aap -sk "$(aap_url)/api/eda/v1/projects/?name=rhel_fleet" \
        | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["results"]; print(r[0]["id"] if r else "")' 2>/dev/null || true)
      if [ -n "${proj_id}" ]; then
        curl_aap -sk -o /dev/null -X POST "$(aap_url)/api/eda/v1/projects/${proj_id}/sync/"
        for _ in $(seq 1 30); do
          [ "$(curl_aap -sk "$(aap_url)/api/eda/v1/projects/${proj_id}/" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["import_state"])' 2>/dev/null)" = "completed" ] && break
          sleep 2
        done
        log "  EDA project rhel_fleet re-imported"
      fi
    else
      echo "eda_rulebook_activations: []" >> "${vars}"
      log "  rulebook activation satellite_as_code exists; kept (AAP_RECREATE_ACTIVATION=true to recreate)"
    fi
  fi
  local rc=0
  ( cd "${GITOPS_DIR}/repo" && ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_DEPRECATION_WARNINGS=False \
      ansible-playbook -i localhost, aap/configure-aap.yml -e "@${vars}" ) || rc=$?
  rm -f "${vars}"
  curl_aap -sk -o /dev/null -X DELETE "$(aap_url)/api/gateway/v1/tokens/${tok_id}/" || true
  trap - EXIT
  [ "${rc}" -eq 0 ] || die "configure-aap.yml failed (is the subscription active? see 'bootstrap.sh aap')"
  log "  done: AAP -> Templates (GitOps · / SAT · / HOST · / VM ·)"
  satellite_executor_wiring
}

# Shared secret for the HMAC-signed Gitea -> EDA event stream webhook.
eda_webhook_secret() {
  local f="${CACHE_DIR}/eda-webhook-secret"
  if [ ! -s "${f}" ]; then
    mkdir -p "${CACHE_DIR}"
    ( umask 077; python3 -I -c 'import secrets; print(secrets.token_hex(24), end="")' > "${f}" )
  fi
  cat "${f}"
}

# Wire the Satellite executor: aap = rulebook activation enabled + Gitea webhook
# to the event stream (secret refreshed every run, so a regenerated
# eda-webhook-secret never leaves a stale hook); argo = activation disabled and
# the hook removed, so the Argo CD PostSync Job is the only executor.
satellite_executor_wiring() {
  local es_url act hook_id
  es_url=$(curl_aap -sk "$(aap_url)/api/eda/v1/event-streams/?name=gitea_push" 2>/dev/null \
    | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["results"]; print(r[0]["url"] if r else "")' 2>/dev/null || true)
  act=$(curl_aap -sk "$(aap_url)/api/eda/v1/activations/?name=satellite_as_code" 2>/dev/null \
    | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["results"]; print("%s %s" % (r[0]["id"], r[0]["is_enabled"]) if r else "")' 2>/dev/null || true)
  hook_id=""
  [ -n "${es_url}" ] && hook_id=$(gitea_api GET "/repos/${GITEA_USER}/${GITEA_REPO}/hooks" \
    | python3 -I -c 'import json,sys; u=sys.argv[1]; print(next((str(h["id"]) for h in json.load(sys.stdin) if h["config"].get("url")==u), ""))' "${es_url}")
  if [ "${SATELLITE_EXECUTOR}" = "aap" ]; then
    [ -n "${es_url}" ] || { warn "event stream gitea_push not found; Satellite as code will not trigger on push"; return 0; }
    if [ -n "${act}" ] && [ "${act#* }" = "False" ]; then
      curl_aap -sk -o /dev/null -X POST "$(aap_url)/api/eda/v1/activations/${act%% *}/enable/" \
        && log "  rulebook activation satellite_as_code enabled"
    fi
    local body
    body=$(python3 -I -c 'import json,sys; print(json.dumps({"type":"gitea","active":True,"events":["push"],"branch_filter":"main","config":{"url":sys.argv[1],"content_type":"json","secret":sys.argv[2]}}))' "${es_url}" "$(eda_webhook_secret)")
    if [ -n "${hook_id}" ]; then
      gitea_api PATCH "/repos/${GITEA_USER}/${GITEA_REPO}/hooks/${hook_id}" "${body}" >/dev/null \
        && log "  Gitea -> EDA webhook up to date (${es_url})"
    else
      gitea_api POST "/repos/${GITEA_USER}/${GITEA_REPO}/hooks" "${body}" >/dev/null \
        && log "  Gitea -> EDA webhook created (${es_url})"
    fi
  else
    if [ -n "${act}" ] && [ "${act#* }" = "True" ]; then
      curl_aap -sk -o /dev/null -X POST "$(aap_url)/api/eda/v1/activations/${act%% *}/disable/" \
        && log "  rulebook activation satellite_as_code disabled (SATELLITE_EXECUTOR=argo)"
    fi
    if [ -n "${hook_id}" ]; then
      gitea_api DELETE "/repos/${GITEA_USER}/${GITEA_REPO}/hooks/${hook_id}" >/dev/null \
        && log "  Gitea -> EDA webhook removed (SATELLITE_EXECUTOR=argo)"
    fi
  fi
}

phase_info() {
  local argo aap
  argo=$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || true)
  aap="$(aap_host 2>/dev/null || true)"
  cat <<EOF

GitOps layer
  Gitea      $(gitea_url 2>/dev/null || echo '?')/${GITEA_USER}/${GITEA_REPO}
             user ${GITEA_USER}, password = DEMO_PASSWORD, token in ${GITEA_TOKEN_FILE}
  Argo CD    https://${argo:-?}   (log in with OpenShift)
  AAP        https://${aap:-?}   admin / password in ${AAP_PASSWORD_FILE}
  Satellite  https://${SAT_FQDN}   admin / DEMO_PASSWORD
Next: gitops/README.md -> "Run sheet"
EOF
}

for p in "${PHASES[@]}"; do
  case "$p" in
    all)
      phase_check; phase_operator; phase_gitea; phase_secrets; phase_runner
      phase_rbac; phase_seed; phase_apps; phase_webhook
      if [ "${AAP_ENABLED:-true}" = "true" ]; then phase_aap; phase_aapconfig; fi
      phase_info ;;
    check|operator|gitea|secrets|runner|rbac|seed|apps|webhook|aap|aapconfig|info) "phase_$p" ;;
    *) die "unknown phase: $p" ;;
  esac
done
