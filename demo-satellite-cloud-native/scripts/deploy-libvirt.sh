#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/../ansible"

echo "=== Cloud-Native Satellite + IdM Demo — Libvirt Deployment ==="
echo ""

# Load environment. DEMO_ENV_FILE lets the local workstation profile keep its
# own .env.local alongside the remote-host .env.
ENV_FILE="${DEMO_ENV_FILE:-${SCRIPT_DIR}/../.env}"
case "${ENV_FILE}" in
  /*) : ;;
  *) ENV_FILE="${SCRIPT_DIR}/../${ENV_FILE}" ;;
esac
if [ -f "${ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

# Profile switches (defaults preserve the original remote-host behaviour)
: "${DEPLOY_IDM:=true}"
: "${DEPLOY_CAPSULE:=false}"
: "${DEMO_LOCAL_PROFILE:=false}"
: "${LAB_DOMAIN:=demo.lab}"

# Validate required variables
: "${LIBVIRT_HOST:?LIBVIRT_HOST not set. Edit your env file and set it to your KVM host (or localhost).}"
: "${SAT_FQDN:?SAT_FQDN not set. Edit your env file with your Satellite DNS name.}"
: "${RHSM_ORG:?RHSM_ORG not set. Edit your env file with your Red Hat subscription org ID.}"
: "${RHSM_ACTIVATION_KEY:?RHSM_ACTIVATION_KEY not set. Edit your env file with your activation key.}"
if [ "${DEPLOY_IDM}" = "true" ]; then
  : "${IDM_FQDN:?IDM_FQDN not set. Edit your env file with your IdM DNS name, or set DEPLOY_IDM=false.}"
fi
if [ "${DEPLOY_CAPSULE}" = "true" ]; then
  : "${CAPSULE_FQDN:?CAPSULE_FQDN not set. Edit your env file with your Capsule DNS name, or set DEPLOY_CAPSULE=false.}"
fi

# Defaults
: "${IDM_FQDN:=}"
: "${CAPSULE_FQDN:=}"
: "${LIBVIRT_USER:=root}"
: "${LIBVIRT_SSH_KEY:=~/.ssh/id_ed25519}"
: "${LIBVIRT_NETWORK:=satellite-demo}"
: "${LIBVIRT_POOL_DIR:=/var/lib/libvirt/images}"
: "${LIBVIRT_RHEL9_IMAGE:=rhel-9.8-x86_64-kvm.qcow2}"
: "${LIBVIRT_RHEL9_IMAGE_SOURCE:=${LIBVIRT_POOL_DIR}}"
: "${LIBVIRT_CENTOS9_IMAGE:=centos-stream-9-x86_64-kvm.qcow2}"
: "${LIBVIRT_CENTOS9_IMAGE_URL:=https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2}"
: "${SAT_TUNING:=}"
: "${SAT_DISABLE_SYSTEM_CHECKS:=false}"

# Generate or load demo password
if [ -z "${DEMO_PASSWORD:-}" ]; then
  DEMO_PASSWORD=$(openssl rand -base64 12)
  # Must be exported: the demo scripts are run as child processes after
  # "source .env", and a bare assignment is not inherited — the child would
  # then fall back to its default env file and target the wrong hypervisor.
  echo "export DEMO_PASSWORD='${DEMO_PASSWORD}'" >> "${ENV_FILE}"
  echo "Generated DEMO_PASSWORD and saved to $(basename "${ENV_FILE}")"
fi

# Derive IPA domain and realm. Without IdM there is no IPA domain, so fall
# back to the lab domain served by the libvirt network's dnsmasq.
if [ -n "${IDM_FQDN}" ]; then
  IPA_DOMAIN="${IDM_FQDN#*.}"
else
  IPA_DOMAIN="${LAB_DOMAIN}"
fi
IPA_REALM=$(echo "${IPA_DOMAIN}" | tr '[:lower:]' '[:upper:]')

echo "Libvirt Host:      ${LIBVIRT_HOST}$([ "${LIBVIRT_HOST}" = "localhost" ] && echo '  (local workstation)')"
echo "IdM FQDN:          ${IDM_FQDN:-<not deployed>}"
echo "Satellite FQDN:    ${SAT_FQDN}"
echo "Capsule FQDN:      ${CAPSULE_FQDN:-<not deployed>}"
echo "IPA domain/realm:  ${IPA_DOMAIN} / ${IPA_REALM}"
echo "Pool directory:    ${LIBVIRT_POOL_DIR}"
echo ""

# Check SSH connectivity to libvirt host
echo "--- Checking connectivity to ${LIBVIRT_HOST} ---"
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "${LIBVIRT_SSH_KEY}" \
  "${LIBVIRT_USER}@${LIBVIRT_HOST}" "echo 'SSH connection OK'" || {
    echo "ERROR: Cannot SSH to ${LIBVIRT_HOST}. Check LIBVIRT_HOST, LIBVIRT_USER, LIBVIRT_SSH_KEY."
    exit 1
  }
echo ""

# Export all variables for Ansible. Every name here must also appear in the
# environment-variables.pass list in ansible/ansible-navigator.yml, otherwise
# it silently arrives empty inside the execution environment.
export LIBVIRT_HOST LIBVIRT_USER LIBVIRT_SSH_KEY LIBVIRT_NETWORK LIBVIRT_POOL_DIR
export LIBVIRT_RHEL9_IMAGE LIBVIRT_RHEL9_IMAGE_SOURCE LIBVIRT_CENTOS9_IMAGE LIBVIRT_CENTOS9_IMAGE_URL
export IDM_FQDN SAT_FQDN CAPSULE_FQDN LAB_DOMAIN DEMO_PASSWORD RHSM_ORG RHSM_ACTIVATION_KEY
export DEPLOY_IDM DEPLOY_CAPSULE DEMO_LOCAL_PROFILE SAT_TUNING SAT_DISABLE_SYSTEM_CHECKS

# Run the full deployment via Ansible
echo "--- Running Ansible deployment ---"
DEPLOY_SUMMARY="set up the libvirt host"
if [ "${DEPLOY_IDM}" = "true" ]; then DEPLOY_SUMMARY="${DEPLOY_SUMMARY}, deploy IdM"; fi
DEPLOY_SUMMARY="${DEPLOY_SUMMARY}, deploy Satellite"
if [ "${DEPLOY_CAPSULE}" = "true" ]; then DEPLOY_SUMMARY="${DEPLOY_SUMMARY}, deploy and join a Capsule"; fi
echo "This will: ${DEPLOY_SUMMARY}, and prepare client templates."
echo ""

EXTRA_VARS="libvirt_host=${LIBVIRT_HOST}"
EXTRA_VARS="${EXTRA_VARS} libvirt_user=${LIBVIRT_USER}"
EXTRA_VARS="${EXTRA_VARS} libvirt_ssh_key=${LIBVIRT_SSH_KEY}"
EXTRA_VARS="${EXTRA_VARS} libvirt_pool_dir=${LIBVIRT_POOL_DIR}"
EXTRA_VARS="${EXTRA_VARS} libvirt_network_name=${LIBVIRT_NETWORK}"
EXTRA_VARS="${EXTRA_VARS} libvirt_rhel9_image=${LIBVIRT_RHEL9_IMAGE}"
EXTRA_VARS="${EXTRA_VARS} libvirt_rhel9_image_source=${LIBVIRT_RHEL9_IMAGE_SOURCE}"
EXTRA_VARS="${EXTRA_VARS} libvirt_centos9_image=${LIBVIRT_CENTOS9_IMAGE}"
EXTRA_VARS="${EXTRA_VARS} idm_fqdn=${IDM_FQDN}"
EXTRA_VARS="${EXTRA_VARS} sat_fqdn=${SAT_FQDN}"
EXTRA_VARS="${EXTRA_VARS} capsule_fqdn=${CAPSULE_FQDN}"
EXTRA_VARS="${EXTRA_VARS} lab_domain=${LAB_DOMAIN}"
EXTRA_VARS="${EXTRA_VARS} deploy_idm=${DEPLOY_IDM}"
EXTRA_VARS="${EXTRA_VARS} deploy_capsule=${DEPLOY_CAPSULE}"
EXTRA_VARS="${EXTRA_VARS} local_profile=${DEMO_LOCAL_PROFILE}"
EXTRA_VARS="${EXTRA_VARS} sat_disable_system_checks=${SAT_DISABLE_SYSTEM_CHECKS}"
if [ -n "${SAT_TUNING}" ]; then
  EXTRA_VARS="${EXTRA_VARS} sat_tuning=${SAT_TUNING}"
fi
EXTRA_VARS="${EXTRA_VARS} demo_password=${DEMO_PASSWORD}"
EXTRA_VARS="${EXTRA_VARS} rhsm_org=${RHSM_ORG}"
EXTRA_VARS="${EXTRA_VARS} rhsm_activation_key=${RHSM_ACTIVATION_KEY}"
EXTRA_VARS="${EXTRA_VARS} ipa_domain=${IPA_DOMAIN}"
EXTRA_VARS="${EXTRA_VARS} ipa_realm=${IPA_REALM}"

if [ -n "${MANIFEST_PATH:-}" ]; then
  if [ ! -f "${MANIFEST_PATH}" ]; then
    echo "WARNING: MANIFEST_PATH set but file not found: ${MANIFEST_PATH}"
  else
    # Copy manifest into the volume-mounted cache dir so it's accessible
    # inside the ansible-navigator EE container
    CACHE_DIR="${HOME}/.cache/satellite-demo"
    mkdir -p "${CACHE_DIR}"
    cp "${MANIFEST_PATH}" "${CACHE_DIR}/manifest.zip"
    EXTRA_VARS="${EXTRA_VARS} manifest_path=/home/runner/.cache/satellite-demo/manifest.zip"
    echo "Manifest copied to EE-accessible path"
  fi
fi

cd "${ANSIBLE_DIR}"
ansible-navigator run deploy-all.yml --extra-vars "${EXTRA_VARS}" "$@"

echo ""
echo "=== Libvirt Deployment Complete ==="
echo ""

# Deploy Caddy reverse proxy if requested. Not needed on the local profile:
# the hypervisor is the workstation, so /etc/hosts already points the browser
# straight at the VMs on the NAT network.
if [ "${DEPLOY_PROXY:-}" = "true" ] || [[ " $* " == *"--proxy"* ]]; then
  echo "--- Deploying Caddy reverse proxy ---"
  ansible-navigator run caddy-proxy.yml \
    -i inventory/libvirt-host.yml \
    --extra-vars "sat_fqdn=${SAT_FQDN} idm_fqdn=${IDM_FQDN} sat_ip=192.168.150.11 idm_ip=192.168.150.10"
  echo ""
fi

ENV_BASE="$(basename "${ENV_FILE}")"
echo "Next steps:"
echo "  1. Verify: source ${ENV_BASE} && ./scripts/verify-registration.sh"
if [ "${DEPLOY_CAPSULE}" = "true" ]; then
  echo "  2. Run the Capsule demos: source ${ENV_BASE} && ./scripts/demo-scenarios.sh d"
else
  echo "  2. Run demos: source ${ENV_BASE} && ./scripts/demo-scenarios.sh a1"
fi
if [ "${DEMO_LOCAL_PROFILE}" != "true" ]; then
  echo "  3. Deploy reverse proxy: $0 --proxy  (or: cd ansible && ansible-navigator run caddy-proxy.yml -i inventory/libvirt-host.yml)"
fi
echo ""
echo "VM Access:"
if [ -n "${IDM_FQDN}" ]; then
  echo "  IdM:       https://${IDM_FQDN}  (admin / ${DEMO_PASSWORD})"
fi
echo "  Satellite: https://${SAT_FQDN}  (admin / ${DEMO_PASSWORD})"
if [ -n "${CAPSULE_FQDN}" ]; then
  echo "  Capsule:   https://${CAPSULE_FQDN}  (content only, no web UI)"
fi
