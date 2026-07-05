#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/../ansible"

echo "=== Cloud-Native Satellite + IdM Demo — Libvirt Deployment ==="
echo ""

# Load environment
if [ -f "${SCRIPT_DIR}/../.env" ]; then
  source "${SCRIPT_DIR}/../.env"
fi

# Validate required variables
: "${LIBVIRT_HOST:?LIBVIRT_HOST not set. Edit .env and set it to your KVM host.}"
: "${IDM_FQDN:?IDM_FQDN not set. Edit .env with your IdM DNS name.}"
: "${SAT_FQDN:?SAT_FQDN not set. Edit .env with your Satellite DNS name.}"
: "${RHSM_ORG:?RHSM_ORG not set. Edit .env with your Red Hat subscription org ID.}"
: "${RHSM_ACTIVATION_KEY:?RHSM_ACTIVATION_KEY not set. Edit .env with your activation key.}"

# Defaults
: "${LIBVIRT_USER:=root}"
: "${LIBVIRT_SSH_KEY:=~/.ssh/id_ed25519}"
: "${LIBVIRT_NETWORK:=satellite-demo}"
: "${LIBVIRT_POOL_DIR:=/var/lib/libvirt/images}"
: "${LIBVIRT_RHEL9_IMAGE:=rhel-9.6-x86_64-kvm.qcow2}"

# Generate or load demo password
if [ -z "${DEMO_PASSWORD:-}" ]; then
  DEMO_PASSWORD=$(openssl rand -base64 12)
  echo "DEMO_PASSWORD='${DEMO_PASSWORD}'" >> "${SCRIPT_DIR}/../.env"
  echo "Generated DEMO_PASSWORD and saved to .env"
fi

# Derive IPA domain and realm
IPA_DOMAIN="${IDM_FQDN#*.}"
IPA_REALM=$(echo "${IPA_DOMAIN}" | tr '[:lower:]' '[:upper:]')

echo "Libvirt Host:      ${LIBVIRT_HOST}"
echo "IdM FQDN:          ${IDM_FQDN}"
echo "Satellite FQDN:    ${SAT_FQDN}"
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

# Export all variables for Ansible
export LIBVIRT_HOST LIBVIRT_USER LIBVIRT_SSH_KEY LIBVIRT_NETWORK LIBVIRT_POOL_DIR LIBVIRT_RHEL9_IMAGE
export IDM_FQDN SAT_FQDN DEMO_PASSWORD RHSM_ORG RHSM_ACTIVATION_KEY

# Run the full deployment via Ansible
echo "--- Running Ansible deployment ---"
echo "This will: set up the libvirt host, deploy IdM, Satellite, and prepare client templates."
echo ""

EXTRA_VARS="libvirt_host=${LIBVIRT_HOST}"
EXTRA_VARS="${EXTRA_VARS} libvirt_user=${LIBVIRT_USER}"
EXTRA_VARS="${EXTRA_VARS} libvirt_ssh_key=${LIBVIRT_SSH_KEY}"
EXTRA_VARS="${EXTRA_VARS} libvirt_pool_dir=${LIBVIRT_POOL_DIR}"
EXTRA_VARS="${EXTRA_VARS} libvirt_network_name=${LIBVIRT_NETWORK}"
EXTRA_VARS="${EXTRA_VARS} libvirt_rhel9_image=${LIBVIRT_RHEL9_IMAGE}"
EXTRA_VARS="${EXTRA_VARS} idm_fqdn=${IDM_FQDN}"
EXTRA_VARS="${EXTRA_VARS} sat_fqdn=${SAT_FQDN}"
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

# Deploy Caddy reverse proxy if requested
if [ "${DEPLOY_PROXY:-}" = "true" ] || [[ " $* " == *"--proxy"* ]]; then
  echo "--- Deploying Caddy reverse proxy ---"
  ansible-navigator run caddy-proxy.yml \
    -i inventory/libvirt-host.yml \
    --extra-vars "sat_fqdn=${SAT_FQDN} idm_fqdn=${IDM_FQDN} sat_ip=192.168.150.11 idm_ip=192.168.150.10"
  echo ""
fi

echo "Next steps:"
echo "  1. Verify: source .env && ./scripts/verify-registration.sh"
echo "  2. Run demos: source .env && ./scripts/demo-scenarios.sh a1"
echo "  3. Deploy reverse proxy: $0 --proxy  (or: cd ansible && ansible-navigator run caddy-proxy.yml -i inventory/libvirt-host.yml)"
echo ""
echo "VM Access:"
echo "  IdM:       https://${IDM_FQDN}  (admin / ${DEMO_PASSWORD})"
echo "  Satellite: https://${SAT_FQDN}  (admin / ${DEMO_PASSWORD})"
