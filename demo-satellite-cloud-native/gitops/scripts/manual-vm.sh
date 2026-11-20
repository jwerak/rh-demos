#!/bin/bash
# V1 - the legacy way: an administrator creates a VM by hand, it registers
# itself to Satellite at first boot. No Git, no review, no record of who asked.
#
# Usage: gitops/scripts/manual-vm.sh NAME [dev|qa|prod] [small|medium|large] [--print|--delete]
#   (default)  oc apply the VM directly to the cluster
#   --print    print the YAML, to paste into the console:
#              Virtualization -> VirtualMachines -> Create -> With YAML
#   --delete   remove the VM again (does not unregister it from Satellite)
#
# The VM uses the same template, cloud-init and registration as V2/V3, so the
# only difference the audience sees is HOW it was created. Argo CD ignores it:
# it is not in Git, so it is neither synced nor pruned.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

MODE=apply
POS=()
for a in "$@"; do
  case "$a" in
    --print) MODE=print ;;
    --delete) MODE=delete ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) POS+=("$a") ;;
  esac
done
NAME="${POS[0]:-}"; ENV="${POS[1]:-dev}"; SIZE="${POS[2]:-small}"
[ -n "${NAME}" ] || { sed -n '2,15p' "$0"; exit 1; }

if [ "${MODE}" = "delete" ]; then
  oc delete vm "${NAME}" -n "${NAMESPACE}" --ignore-not-found
  echo "Host record stays in Satellite: Hosts -> All Hosts -> ${NAME} -> Delete (or hammer host delete)."
  exit 0
fi

out=$(mktemp --suffix=.yaml)
trap 'rm -f "${out}"' EXIT
render_vm "${NAME}" "${ENV}" "${SIZE}" manual "${out}"

if [ "${MODE}" = "print" ]; then
  cat "${out}"
  exit 0
fi

oc get secret "fleet-cloudinit-${ENV}" -n "${NAMESPACE}" >/dev/null 2>&1 \
  || die "Secret fleet-cloudinit-${ENV} missing (run gitops/scripts/bootstrap.sh secrets)"
oc apply -f "${out}"
cat <<EOF

${NAME} created by hand in ${ENV}. Watch it:
  oc get vm,vmi ${NAME} -n ${NAMESPACE} -w
  Satellite: Hosts -> All Hosts (search: name ~ ${NAME})   ~5-8 min to register
  Log on the VM: run_on_vm ${NAME} "sudo tail -f /var/log/client-setup.log"
EOF
