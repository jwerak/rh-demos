#!/bin/bash
# Deploy the Standard Operating Environment demo stack on this workstation:
#
#   satellite  (satellite-local profile, 12 GB)
#   lc-dev     )
#   lc-qa      ) lc-client-soe profile, 1536 MB each
#   lc-prod    )
#   centos     (centos-client-soe profile, 1536 MB)
#
# A variant of deploy-local.sh with the Capsule off and the three lifecycle
# clients pre-staged. The Capsule and OpenShift/remote-KVM paths are
# untouched.
#
# Phases and honest timings on a 14-core / 30 GB workstation:
#
#   0  pre-flight                              <1 min
#   1  libvirt host setup + image staging      2-10 min  (CentOS image download)
#   2  Satellite VM install                    70-150 min  <-- run the day before
#   3  Section C1 pipeline + 3 client VMs      25-40 min   <-- run the day before
#   4  Section E1 CentOS client                10-15 min   <-- run the day before
#
# Phases 0-4 are all re-runnable. Nothing in them is needed live; the
# 25-minute demo itself only replays c2/c3/e2 against the built state.
#
# Usage:
#   ./scripts/deploy-soe.sh                 # everything (phases 0-4)
#   ./scripts/deploy-soe.sh --infra-only    # phases 0-2, stop after Satellite
#   ./scripts/deploy-soe.sh --clients-only  # phases 3-4, Satellite must exist
#   ./scripts/deploy-soe.sh --check         # phase 0 only, change nothing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="${SCRIPT_DIR}/.."

INFRA_ONLY=false
CLIENTS_ONLY=false
CHECK_ONLY=false
PASSTHRU=()
for arg in "$@"; do
  case "${arg}" in
    --infra-only)   INFRA_ONLY=true ;;
    --clients-only) CLIENTS_ONLY=true ;;
    --check)        CHECK_ONLY=true ;;
    *)              PASSTHRU+=("${arg}") ;;
  esac
done

echo "=== Satellite SOE Demo — Local Workstation Deployment ==="
echo ""

ENV_FILE="${DEMO_ENV_FILE:-.env.soe}"
case "${ENV_FILE}" in
  /*) ENV_PATH="${ENV_FILE}" ;;
  *)  ENV_PATH="${DEMO_DIR}/${ENV_FILE}" ;;
esac

if [ ! -f "${ENV_PATH}" ]; then
  echo "ERROR: ${ENV_PATH} not found."
  echo "       cp .env.soe.sample .env.soe  and edit it first."
  exit 1
fi
# shellcheck disable=SC1090
source "${ENV_PATH}"

: "${LIBVIRT_USER:=$(id -un)}"
: "${LIBVIRT_SSH_KEY:=${HOME}/.ssh/id_ed25519}"
: "${LIBVIRT_POOL_DIR:=/var/lib/libvirt/images}"
: "${LIBVIRT_RHEL9_IMAGE:=rhel-9.8-x86_64-kvm.qcow2}"
: "${LIBVIRT_RHEL9_IMAGE_SOURCE:=${LIBVIRT_POOL_DIR}}"
: "${LC_VM_PROFILE:=lc-client-soe}"
: "${CENTOS_VM_PROFILE:=centos-client-soe}"
# Exported explicitly rather than relying on the env file having used
# "export": phases 3 and 4 are child processes, and a bare assignment would
# leave them building 2048 MB guests and blowing the RAM budget.
export LC_VM_PROFILE CENTOS_VM_PROFILE DEPLOY_CENTOS DEMO_PLATFORM

FAILED=0
pass() { echo "  [ ok ] $1"; }
fail() { echo "  [FAIL] $1"; FAILED=1; }
warn() { echo "  [warn] $1"; }

# ════════════════════════════════════════════════════════════════════════
# Phase 0: Pre-flight
# ════════════════════════════════════════════════════════════════════════
# Everything that can be known before a single VM is created is checked
# here. The one thing that cannot — whether the activation key entitles
# satellite-6.19 — is caught at the repository checkpoint in
# deploy-all.yml, about 10 minutes in rather than 80.

echo "--- Phase 0: Pre-flight ---"

# --- Profile sanity ---
if [ "${DEMO_PLATFORM:-}" != "libvirt" ]; then
  fail "DEMO_PLATFORM must be libvirt in ${ENV_FILE} (got '${DEMO_PLATFORM:-unset}')"
else
  pass "DEMO_PLATFORM=libvirt"
fi

if [ "${DEPLOY_CAPSULE:-false}" = "true" ]; then
  fail "DEPLOY_CAPSULE=true in ${ENV_FILE}. The SOE profile has no Capsule;"
  echo "         its 6 GB is what makes room for the three lifecycle clients."
  echo "         Use ./scripts/deploy-local.sh with .env.local for the Capsule demo."
else
  pass "Capsule is off (frees 6 GB for the lifecycle clients)"
fi

for V in RHSM_ORG RHSM_ACTIVATION_KEY SAT_FQDN LAB_DOMAIN; do
  if [ -z "${!V:-}" ]; then
    fail "${V} is not set in ${ENV_FILE}"
  fi
done
[ -n "${RHSM_ORG:-}" ] && [ -n "${RHSM_ACTIVATION_KEY:-}" ] \
  && pass "RHSM org and activation key are set (entitlement verified at the repo checkpoint)"

# --- Loopback SSH: the whole local profile rests on it ---
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

# --- libvirt group membership ---
# A warning in deploy-local.sh, a hard failure here: without it qemu+ssh://
# prompts polkit for a password and the EE, which has no tty, hangs.
if id -nG "${LIBVIRT_USER}" | tr ' ' '\n' | grep -qx libvirt; then
  pass "${LIBVIRT_USER} is in the libvirt group"
else
  fail "${LIBVIRT_USER} is not in the libvirt group"
  echo "         sudo usermod -aG libvirt ${LIBVIRT_USER}"
  echo "         then log out and back in — a new login is required, newgrp is"
  echo "         not enough for the SSH session the EE opens."
fi

# --- virsh reaches the system instance ---
if virsh -c qemu:///system list --all >/dev/null 2>&1; then
  pass "virsh can reach qemu:///system"
else
  fail "virsh -c qemu:///system failed (libvirtd not running, or no permission)"
fi

# --- Execution environment ---
if podman image exists satellite-demo-ee:latest 2>/dev/null; then
  pass "execution environment satellite-demo-ee:latest"
else
  fail "EE image missing — build it: cd ansible && ansible-builder build -t satellite-demo-ee:latest"
fi

# --- RHEL base image ---
if [ -r "${LIBVIRT_RHEL9_IMAGE_SOURCE}/${LIBVIRT_RHEL9_IMAGE}" ] \
   || sudo -n test -r "${LIBVIRT_POOL_DIR}/${LIBVIRT_RHEL9_IMAGE}" 2>/dev/null; then
  pass "RHEL 9 base image ${LIBVIRT_RHEL9_IMAGE}"
else
  fail "RHEL 9 base image not found at ${LIBVIRT_RHEL9_IMAGE_SOURCE}/${LIBVIRT_RHEL9_IMAGE}"
  echo "         Download it from access.redhat.com and set LIBVIRT_RHEL9_IMAGE_SOURCE."
fi

# --- RAM ---
# 12288 (satellite) + 4 * 1536 (lc-dev, lc-qa, lc-prod, centos) = 18432 MB.
# Read the real numbers out of vm-profiles.yml rather than restating them,
# so a profile edit cannot drift away from this check.
_profile_ram() {
  python3 -I -c "
import re,sys
key=sys.argv[1]; want=None; cur=None
for line in open(sys.argv[2]):
    m=re.match(r'^  ([A-Za-z0-9_-]+):\s*$', line)
    if m: cur=m.group(1)
    m=re.match(r'^    ram_mb:\s*(\d+)', line)
    if m and cur==key: want=int(m.group(1))
print(want or 0)
" "$1" "${DEMO_DIR}/ansible/vars/vm-profiles.yml" 2>/dev/null || echo 0
}
SAT_RAM=$(_profile_ram satellite-local)
LC_RAM=$(_profile_ram "${LC_VM_PROFILE}")
CENTOS_RAM=$(_profile_ram "${CENTOS_VM_PROFILE}")
NEEDED_MB=$(( ${SAT_RAM:-12288} + 3 * ${LC_RAM:-1536} + ${CENTOS_RAM:-1536} ))
TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)

echo "  [info] guest RAM budget: satellite ${SAT_RAM} + 3 x ${LC_RAM} + centos ${CENTOS_RAM} = ${NEEDED_MB} MB"

if [ "${TOTAL_MB}" -lt "$(( NEEDED_MB + 4096 ))" ]; then
  fail "this machine has ${TOTAL_MB} MB total RAM; ${NEEDED_MB} MB of guests plus"
  echo "         ~4 GB for the host leaves nothing. The SOE profile does not fit here."
elif [ "${AVAIL_MB}" -ge "${NEEDED_MB}" ]; then
  pass "available RAM ${AVAIL_MB} MB (guests need ${NEEDED_MB} MB)"
else
  warn "available RAM is ${AVAIL_MB} MB but the guests need ${NEEDED_MB} MB."
  echo "         Close your browser and other heavy applications before the"
  echo "         Satellite install, or the OOM killer will interrupt"
  echo "         satellite-installer and leave a half-configured Satellite."
  echo "         KSM is enabled by host setup and reclaims some of this back"
  echo "         once the near-identical RHEL guests are all running."
fi

# --- Disk ---
# Satellite: 80 GB root overlay + 60 GB pulp disk, both sparse qcow2. With no
# subscription manifest the real consumption is ~25-30 GB. Four clients at
# 20 GB sparse add ~2 GB each. 60 GB free is the realistic floor; 100 GB is
# comfortable and leaves room should a manifest be added later.
FREE_GB=$(df -BG --output=avail "${LIBVIRT_POOL_DIR}" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -z "${FREE_GB}" ]; then
  warn "could not determine free space in ${LIBVIRT_POOL_DIR}"
elif [ "${FREE_GB}" -lt 60 ]; then
  fail "only ${FREE_GB} GB free in ${LIBVIRT_POOL_DIR}; 60 GB is the floor"
  echo "         (sparse qcow2: ~30 GB Satellite + ~2 GB per client + base images)"
elif [ "${FREE_GB}" -lt 100 ]; then
  warn "${FREE_GB} GB free in ${LIBVIRT_POOL_DIR}; works, but 100 GB is comfortable"
else
  pass "free space in ${LIBVIRT_POOL_DIR}: ${FREE_GB} GB"
fi

# --- Stale artifacts from a previous profile ---
STALE=$(sudo -n find "${LIBVIRT_POOL_DIR}" -maxdepth 1 -name 'capsule*.qcow2' -o -maxdepth 1 -name 'capsule-cidata.iso' 2>/dev/null | wc -l)
if [ "${STALE:-0}" -gt 0 ]; then
  warn "Capsule disks from a previous .env.local run are still in the pool."
  echo "         They are not used by this profile. Reclaim the space with:"
  echo "         ./scripts/teardown-soe.sh --orphans"
fi

echo ""
if [ "${FAILED}" -ne 0 ]; then
  echo "Pre-flight failed. Fix the items above and re-run."
  exit 1
fi
echo "Pre-flight passed."
echo ""

if [ "${CHECK_ONLY}" = "true" ]; then
  echo "--check given; stopping before any change."
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════
# Phases 1-2: host setup and Satellite, via the ordinary libvirt path
# ════════════════════════════════════════════════════════════════════════
if [ "${CLIENTS_ONLY}" != "true" ]; then
  echo "--- Phases 1-2: libvirt host setup and Satellite (70-150 min) ---"
  echo ""
  DEMO_ENV_FILE="${ENV_PATH}" "${SCRIPT_DIR}/deploy-libvirt.sh" "${PASSTHRU[@]+"${PASSTHRU[@]}"}"
  echo ""
fi

if [ "${INFRA_ONLY}" = "true" ]; then
  echo "--infra-only given; the Satellite is up and the clients are not built."
  echo "Finish later with: ./scripts/deploy-soe.sh --clients-only"
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════
# Phases 3-4: build the demo state
# ════════════════════════════════════════════════════════════════════════
# Both are plain demo sections run in batch mode. DEMO_MODE=auto makes
# demo-lib.sh run every step without prompting, which is what distinguishes
# "build the state the day before" from "present it".
echo "--- Phase 3: lifecycle pipeline and the three clients (25-40 min) ---"
echo ""
DEMO_ENV_FILE="${ENV_PATH}" DEMO_MODE=auto "${SCRIPT_DIR}/demo-scenarios.sh" c1

echo ""
echo "--- Phase 4: the CentOS Stream client (10-15 min) ---"
echo ""
DEMO_ENV_FILE="${ENV_PATH}" DEMO_MODE=auto "${SCRIPT_DIR}/demo-scenarios.sh" e1

echo ""
echo "=== SOE deployment complete ==="
echo ""
virsh -c qemu:///system list --all 2>/dev/null || true
echo ""
echo "Satellite UI: https://${SAT_FQDN}   (admin / \$DEMO_PASSWORD)"
echo ""
echo "Dry-run the demo now, then leave the VMs running:"
echo "  source ${ENV_FILE} && ./scripts/demo-scenarios.sh c2"
echo ""
echo "Run sheet: RUNSHEET-soe.md"
