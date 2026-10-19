#!/bin/bash
# Deploy the Satellite + Capsule + CentOS client stack on this workstation.
#
# Thin wrapper around deploy-libvirt.sh: it pre-flights the things that are
# specific to running the hypervisor and the controller on the same laptop,
# then hands over. Everything downstream is the ordinary libvirt path with
# LIBVIRT_HOST=localhost, so the deploy reaches the host over loopback SSH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="${SCRIPT_DIR}/.."

echo "=== Satellite + Capsule Demo — Local Workstation Deployment ==="
echo ""

ENV_FILE="${DEMO_ENV_FILE:-.env.local}"
case "${ENV_FILE}" in
  /*) ENV_PATH="${ENV_FILE}" ;;
  *) ENV_PATH="${DEMO_DIR}/${ENV_FILE}" ;;
esac

if [ ! -f "${ENV_PATH}" ]; then
  echo "ERROR: ${ENV_PATH} not found."
  echo "       cp .env.local.sample .env.local  and edit it first."
  exit 1
fi
# shellcheck disable=SC1090
source "${ENV_PATH}"

: "${LIBVIRT_USER:=$(id -un)}"
: "${LIBVIRT_SSH_KEY:=${HOME}/.ssh/id_ed25519}"
: "${LIBVIRT_POOL_DIR:=/var/lib/libvirt/images}"
: "${LIBVIRT_RHEL9_IMAGE:=rhel-9.8-x86_64-kvm.qcow2}"
: "${LIBVIRT_RHEL9_IMAGE_SOURCE:=${LIBVIRT_POOL_DIR}}"

FAILED=0
pass() { echo "  [ ok ] $1"; }
fail() { echo "  [FAIL] $1"; FAILED=1; }
warn() { echo "  [warn] $1"; }

echo "--- Pre-flight ---"

# The whole local profile rests on being able to SSH to ourselves: the EE
# container reaches libvirt over qemu+ssh://, and VM access proxies through
# the same hop.
if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
     -i "${LIBVIRT_SSH_KEY}" "${LIBVIRT_USER}@localhost" true 2>/dev/null; then
  pass "loopback SSH as ${LIBVIRT_USER}@localhost"
else
  fail "cannot SSH to ${LIBVIRT_USER}@localhost with ${LIBVIRT_SSH_KEY}"
  echo "         sudo systemctl enable --now sshd"
  echo "         ssh-copy-id -i ${LIBVIRT_SSH_KEY}.pub ${LIBVIRT_USER}@localhost"
fi

if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
     -i "${LIBVIRT_SSH_KEY}" "${LIBVIRT_USER}@localhost" "sudo -n true" 2>/dev/null; then
  pass "passwordless sudo over SSH"
else
  fail "passwordless sudo over SSH is required (host setup runs with become)"
fi

if podman image exists satellite-demo-ee:latest 2>/dev/null; then
  pass "execution environment satellite-demo-ee:latest"
else
  fail "EE image missing — build it: cd ansible && ansible-builder build -t satellite-demo-ee:latest"
fi

if id -nG "${LIBVIRT_USER}" | tr ' ' '\n' | grep -qx libvirt; then
  pass "${LIBVIRT_USER} is in the libvirt group"
else
  warn "${LIBVIRT_USER} is not in the libvirt group yet; host setup adds it,"
  echo "         but you must log out and back in before qemu+ssh:// stops"
  echo "         prompting polkit for a password."
fi

if [ -r "${LIBVIRT_RHEL9_IMAGE_SOURCE}/${LIBVIRT_RHEL9_IMAGE}" ] \
   || sudo -n test -r "${LIBVIRT_POOL_DIR}/${LIBVIRT_RHEL9_IMAGE}" 2>/dev/null; then
  pass "RHEL 9 base image ${LIBVIRT_RHEL9_IMAGE}"
else
  fail "RHEL 9 base image not found at ${LIBVIRT_RHEL9_IMAGE_SOURCE}/${LIBVIRT_RHEL9_IMAGE}"
  echo "         Download it from access.redhat.com and set LIBVIRT_RHEL9_IMAGE_SOURCE."
fi

# The CentOS Stream image is downloaded by host setup, so only report it.
AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
NEEDED_MB=$(( ${SAT_RAM_MB:-12288} + ${CAP_RAM_MB:-6144} ))
if [ "${AVAIL_MB}" -ge "${NEEDED_MB}" ]; then
  pass "available RAM ${AVAIL_MB} MB (servers need ~${NEEDED_MB} MB)"
else
  warn "available RAM ${AVAIL_MB} MB is below the ~${NEEDED_MB} MB the Satellite"
  echo "         and Capsule want concurrently. Close heavy applications before"
  echo "         the install, or the OOM killer will interrupt satellite-installer."
fi

FREE_GB=$(df -BG --output=avail "${LIBVIRT_POOL_DIR}" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "${FREE_GB}" ] && [ "${FREE_GB}" -ge 80 ]; then
  pass "free space in ${LIBVIRT_POOL_DIR}: ${FREE_GB} GB"
else
  warn "only ${FREE_GB:-?} GB free in ${LIBVIRT_POOL_DIR}; 80 GB is a comfortable floor"
fi

echo ""
if [ "${FAILED}" -ne 0 ]; then
  echo "Pre-flight failed. Fix the items above and re-run."
  exit 1
fi

echo "--- Handing over to deploy-libvirt.sh ---"
echo ""
DEMO_ENV_FILE="${ENV_PATH}" exec "${SCRIPT_DIR}/deploy-libvirt.sh" "$@"
