#!/usr/bin/env bash
# Boot the desktop in libvirt.
#   ./scripts/run-libvirt.sh        preinstalled qcow2
#   ./scripts/run-libvirt.sh iso    Anaconda kickstart install from the ISO
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-qcow2}"

require_absent() {
	local name="$1"
	if sudo virsh dominfo "${name}" >/dev/null 2>&1; then
		echo "error: VM ${name} already exists." >&2
		echo "Remove it with: sudo virsh destroy ${name} && sudo virsh undefine ${name} --nvram" >&2
		exit 1
	fi
}

run_vm() {
	sudo virt-install \
		--cpu host \
		--vcpus 4 \
		--memory 4096 \
		--os-variant fedora43 \
		--graphics spice,listen=127.0.0.1 \
		--video virtio \
		--network network=default \
		--autoconsole graphical \
		"$@"
}

case "${mode}" in
qcow2)
	name="fedora-desktop-bootc"
	disk="${root}/output/qcow2/disk.qcow2"
	if [[ ! -f "${disk}" ]]; then
		echo "error: missing ${disk}. Run ./scripts/build-images.sh qcow2 first." >&2
		exit 1
	fi
	require_absent "${name}"
	run_vm \
		--name "${name}" \
		--import \
		--disk "${disk},format=qcow2" \
		--boot uefi
	;;
iso)
	name="fedora-desktop-bootc-install"
	iso="${root}/output/iso/install.iso"
	if [[ ! -f "${iso}" ]]; then
		mapfile -d '' isos < <(find "${root}/output" -type f -name '*.iso' -print0)
		if ((${#isos[@]} == 0)); then
			echo "error: no ISO under ${root}/output. Run ./scripts/build-images.sh iso first." >&2
			exit 1
		fi
		iso="${isos[0]}"
		for candidate in "${isos[@]}"; do
			if [[ "${candidate}" == */install.iso ]]; then
				iso="${candidate}"
				break
			fi
		done
	fi
	require_absent "${name}"
	mkdir -p "${root}/output/install"
	disk="${root}/output/install/disk.qcow2"
	if [[ -f "${disk}" ]]; then
		disk_arg="${disk},format=qcow2"
	else
		disk_arg="${disk},size=20,format=qcow2"
	fi
	echo "Booting ${iso}"
	echo "GRUB waits 5s, then the kickstart wipes ${disk} and installs."
	echo "After reboot the ISO is ejected and the VM boots the installed system."
	run_vm \
		--name "${name}" \
		--disk "${disk_arg}" \
		--cdrom "${iso}" \
		--boot uefi,cdrom,hd
	;;
*)
	echo "usage: $0 [qcow2|iso]" >&2
	exit 1
	;;
esac
