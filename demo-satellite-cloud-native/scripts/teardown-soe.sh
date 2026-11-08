#!/bin/bash
# Tear the SOE demo down and return the workstation to its prior state.
#
# Default: remove the five demo VMs, their overlay disks and cloud-init
# ISOs, and their entries in the VM registry. Shared base images, the
# libvirt network and the storage pool are left alone — they are what makes
# a re-deploy fast, and the network is also used by .env.local.
#
# Usage:
#   ./scripts/teardown-soe.sh               # the five SOE VMs
#   ./scripts/teardown-soe.sh --vms-only    # same, skip the orphan sweep
#   ./scripts/teardown-soe.sh --orphans     # also sweep disks with no VM
#   ./scripts/teardown-soe.sh --all         # also the network, host /etc/hosts
#                                           # entries and the base images
#   ./scripts/teardown-soe.sh --dry-run     # print, change nothing
#
# --all is the full undo. Everything short of it is safe to run between
# rehearsals.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="${SCRIPT_DIR}/.."
ANSIBLE_DIR="${DEMO_DIR}/ansible"

MODE_ORPHANS=false
MODE_ALL=false
DRY_RUN=false
VMS_ONLY=false
for arg in "$@"; do
  case "${arg}" in
    --orphans)  MODE_ORPHANS=true ;;
    --all)      MODE_ALL=true; MODE_ORPHANS=true ;;
    --vms-only) VMS_ONLY=true ;;
    --dry-run)  DRY_RUN=true ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *)          echo "Unknown option: ${arg}"; exit 1 ;;
  esac
done

ENV_FILE="${DEMO_ENV_FILE:-.env.soe}"
case "${ENV_FILE}" in
  /*) ENV_PATH="${ENV_FILE}" ;;
  *)  ENV_PATH="${DEMO_DIR}/${ENV_FILE}" ;;
esac
if [ -f "${ENV_PATH}" ]; then
  # shellcheck disable=SC1090
  source "${ENV_PATH}"
fi

: "${LIBVIRT_HOST:=localhost}"
: "${LIBVIRT_USER:=$(id -un)}"
: "${LIBVIRT_SSH_KEY:=${HOME}/.ssh/id_ed25519}"
: "${LIBVIRT_POOL_DIR:=/var/lib/libvirt/images}"
: "${LIBVIRT_NETWORK:=satellite-demo}"
: "${LIBVIRT_RHEL9_IMAGE:=rhel-9.8-x86_64-kvm.qcow2}"
: "${LIBVIRT_CENTOS9_IMAGE:=centos-stream-9-x86_64-kvm.qcow2}"

SOE_VMS=(lc-dev lc-qa lc-prod centos satellite)

run() {
  if [ "${DRY_RUN}" = "true" ]; then
    echo "  [dry-run] $*"
  else
    eval "$@"
  fi
}

# Always address the system instance: virsh defaults to qemu:///session for
# a non-root user, so every lookup would silently miss the demo VMs.
_virsh() { virsh -c qemu:///system "$@"; }

echo "=== SOE Demo Teardown ==="
[ "${DRY_RUN}" = "true" ] && echo "(dry run — nothing will be changed)"
echo ""

# ── 1. VMs ───────────────────────────────────────────────────────────────
echo "--- Removing demo VMs ---"
for VM in "${SOE_VMS[@]}"; do
  if _virsh list --all --name 2>/dev/null | grep -qx "${VM}"; then
    echo "  ${VM}: deleting"
    # libvirt-vm-delete.yml carries the protected-base-image list, so it is
    # used rather than a hand-rolled virsh + rm. Deleting the VM named
    # "centos" with a glob would otherwise also match
    # centos-stream-9-x86_64-kvm.qcow2, the shared backing file.
    run "(cd '${ANSIBLE_DIR}' && ansible-navigator run libvirt-vm-delete.yml \
      --extra-vars \"vm_name=${VM} libvirt_host=${LIBVIRT_HOST} libvirt_uri=qemu+ssh://${LIBVIRT_USER}@${LIBVIRT_HOST}/system\")"
  else
    echo "  ${VM}: not defined, skipping"
  fi
done
echo ""

if [ "${VMS_ONLY}" = "true" ]; then
  echo "--vms-only given; stopping here."
  exit 0
fi

# ── 2. Orphaned disks ────────────────────────────────────────────────────
# Overlays and cloud-init ISOs left behind by an interrupted run, or by a
# previous .env.local run that built a Capsule. Base images listed in
# vm-profiles.yml are never candidates.
if [ "${MODE_ORPHANS}" = "true" ]; then
  echo "--- Sweeping orphaned disks in ${LIBVIRT_POOL_DIR} ---"
  PROTECTED=("${LIBVIRT_RHEL9_IMAGE}" "${LIBVIRT_CENTOS9_IMAGE}" "cis-rhel9.qcow2")
  DEFINED=$(_virsh list --all --name 2>/dev/null | grep . || true)

  while IFS= read -r FILE; do
    [ -n "${FILE}" ] || continue
    BASE=$(basename "${FILE}")

    SKIP=false
    for P in "${PROTECTED[@]}"; do
      [ "${BASE}" = "${P}" ] && SKIP=true
    done
    ${SKIP} && { echo "  ${BASE}: protected base image, keeping"; continue; }

    # Derive the VM name: foo.qcow2, foo-cidata.iso, foo-pulp-data.qcow2
    OWNER="${BASE%.qcow2}"; OWNER="${OWNER%.iso}"
    OWNER="${OWNER%-cidata}"; OWNER="${OWNER%-pulp-data}"

    if echo "${DEFINED}" | grep -qx "${OWNER}"; then
      echo "  ${BASE}: belongs to running VM ${OWNER}, keeping"
    else
      echo "  ${BASE}: orphaned, removing"
      run "sudo rm -f '${FILE}'"
    fi
  done < <(sudo find "${LIBVIRT_POOL_DIR}" -maxdepth 1 \( -name '*.qcow2' -o -name '*-cidata.iso' \) 2>/dev/null)
  echo ""
fi

# ── 3. Full undo ─────────────────────────────────────────────────────────
if [ "${MODE_ALL}" = "true" ]; then
  echo "--- Full undo: network, host /etc/hosts, base images ---"

  if _virsh net-list --all --name 2>/dev/null | grep -qx "${LIBVIRT_NETWORK}"; then
    echo "  network ${LIBVIRT_NETWORK}: destroying and undefining"
    run "_virsh net-destroy '${LIBVIRT_NETWORK}' || true"
    run "_virsh net-undefine '${LIBVIRT_NETWORK}' || true"
  else
    echo "  network ${LIBVIRT_NETWORK}: not defined"
  fi

  # The marker is written by libvirt-host-setup.yml's blockinfile.
  if sudo grep -q '# BEGIN satellite-demo' /etc/hosts 2>/dev/null; then
    echo "  /etc/hosts: removing the satellite-demo block"
    run "sudo sed -i '/# BEGIN satellite-demo/,/# END satellite-demo/d' /etc/hosts"
  else
    echo "  /etc/hosts: no satellite-demo block"
  fi

  for IMG in "${LIBVIRT_CENTOS9_IMAGE}"; do
    if sudo test -f "${LIBVIRT_POOL_DIR}/${IMG}"; then
      echo "  ${IMG}: removing (downloaded by host setup, re-fetched on next deploy)"
      run "sudo rm -f '${LIBVIRT_POOL_DIR}/${IMG}'"
    fi
  done
  echo "  ${LIBVIRT_RHEL9_IMAGE}: keeping (you downloaded it manually)"

  # KSM was switched on for the demo guests; leaving it on is harmless but
  # it was not the machine's prior state.
  if [ -f /etc/tmpfiles.d/satellite-demo-ksm.conf ]; then
    echo "  KSM: reverting the tmpfiles drop-in installed by host setup"
    run "sudo rm -f /etc/tmpfiles.d/satellite-demo-ksm.conf"
    run "sudo systemctl disable --now ksmtuned.service ksm.service 2>/dev/null || true"
  fi
  echo ""
fi

# ── 4. Registry ──────────────────────────────────────────────────────────
REGISTRY="${HOME}/.cache/satellite-demo/vm-registry.json"
if [ -f "${REGISTRY}" ]; then
  echo "--- VM registry ---"
  if [ "${MODE_ALL}" = "true" ]; then
    echo "  removing ${REGISTRY}"
    run "rm -f '${REGISTRY}'"
  else
    # Prune entries whose VM no longer exists. _libvirt_get_vm_ip consults
    # this file before falling back to virsh, so a stale DHCP address from a
    # previous run (e.g. centos at .115) would be handed out for a VM that
    # now has a different lease, and every run_on_vm would SSH into nothing.
    DEFINED_LIST=$(_virsh list --all --name 2>/dev/null | grep . | paste -sd, - || true)
    if [ "${DRY_RUN}" = "true" ]; then
      echo "  [dry-run] would prune entries not in: ${DEFINED_LIST:-<none>}"
      cat "${REGISTRY}"
    else
      python3 -I -c "
import json, sys
path, defined = sys.argv[1], [x for x in sys.argv[2].split(',') if x]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(0)
stale = [k for k in d if k not in defined]
for k in stale:
    print('  pruning stale entry: %s -> %s' % (k, d.pop(k)))
if not stale:
    print('  no stale entries')
json.dump(d, open(path, 'w'), indent=2)
" "${REGISTRY}" "${DEFINED_LIST}"
      echo "  remaining entries:"
      sed 's/^/    /' "${REGISTRY}"
    fi
  fi
  echo ""
fi

echo "=== Teardown complete ==="
echo ""
_virsh list --all 2>/dev/null || true
echo ""
df -h "${LIBVIRT_POOL_DIR}" 2>/dev/null | tail -1
