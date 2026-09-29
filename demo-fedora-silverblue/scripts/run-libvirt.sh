#!/usr/bin/env bash
# Unattended Fedora Silverblue 44 install in libvirt.
#   ./scripts/download-iso.sh
#   ./scripts/run-libvirt.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="fedora-silverblue-44"
iso="${root}/output/iso/Fedora-Silverblue-ostree-x86_64-44-1.7.iso"
disk="${root}/output/install/disk.qcow2"
key="${root}/output/ssh/id_ed25519"
ks="${root}/output/silverblue.ks"

require_absent() {
	if sudo virsh dominfo "${name}" >/dev/null 2>&1; then
		echo "error: VM ${name} already exists." >&2
		echo "Remove it with: sudo virsh destroy ${name} && sudo virsh undefine ${name} --nvram" >&2
		exit 1
	fi
}

if [[ ! -f "${iso}" ]]; then
	echo "error: missing ${iso}. Run ./scripts/download-iso.sh first." >&2
	exit 1
fi
if [[ -e "${disk}" ]]; then
	echo "error: ${disk} already exists. Remove output/install/ to reinstall." >&2
	exit 1
fi

require_absent
mkdir -p "${root}/output/install" "${root}/output/ssh"

if [[ ! -f "${key}" ]]; then
	ssh-keygen -t ed25519 -N "" -C "fedora-silverblue-44-demo" -f "${key}"
fi

sed "s|__DEMO_SSH_PUBKEY__|$(cat "${key}.pub")|" \
	"${root}/config/silverblue.ks" > "${ks}"

echo "Installing Silverblue 44 onto ${disk}."
echo "Kickstart wipes only vda. Login is demo/demo, GDM autologin, SSH via ${key}."
echo "Leave this window open until the guest reboots into the desktop."
echo "virt-install then drops the installer kernel and boots the installed disk."
echo "After that reboot, run ./scripts/reproduce-fusermount.sh from another terminal."

sudo virt-install \
	--name "${name}" \
	--cpu host \
	--vcpus 4 \
	--memory 4096 \
	--os-variant silverblue43 \
	--graphics spice,listen=127.0.0.1 \
	--video virtio \
	--network network=default \
	--disk "${disk},size=40,format=qcow2" \
	--location "${iso},kernel=images/pxeboot/vmlinuz,initrd=images/pxeboot/initrd.img" \
	--initrd-inject "${ks}" \
	--extra-args "inst.ks=file:/silverblue.ks inst.stage2=hd:LABEL=Fedora-SB-ostree-x86_64-44 inst.repo=hd:LABEL=Fedora-SB-ostree-x86_64-44 inst.text" \
	--boot uefi \
	--autoconsole graphical
