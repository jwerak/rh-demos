#!/usr/bin/env bash
# Build the bootc desktop container, then an Anaconda ISO and a qcow2 disk.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

mapfile -d '' videos < <(find videos -type f \
	\( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' \
		-o -iname '*.mov' -o -iname '*.avi' -o -iname '*.m4v' \) \
	-print0)

if ((${#videos[@]} == 0)); then
	echo "error: put at least one video (mp4, mkv, webm, mov, avi, m4v) into ${root}/videos before building" >&2
	exit 1
fi

sudo podman build \
	-t localhost/fedora-desktop-bootc:latest \
	-f Containerfile \
	.

# The image builder rejects a request that mixes an ISO with a disk image.
build_type() {
	local image_type="$1"
	local dest="$2"
	local -a podman_config=()
	local -a bib_config=()

	if [[ "${image_type}" == "iso" ]]; then
		podman_config=(-v "${root}/config/config.toml":/config.toml:ro)
		bib_config=(--config /config.toml)
	fi

	mkdir -p "${dest}"
	sudo podman run \
		--rm \
		--privileged \
		--pull=newer \
		--security-opt label=type:unconfined_t \
		-v /var/lib/containers/storage:/var/lib/containers/storage \
		-v "${dest}":/output \
		"${podman_config[@]}" \
		quay.io/centos-bootc/bootc-image-builder:latest \
		--type "${image_type}" \
		--rootfs xfs \
		"${bib_config[@]}" \
		--chown "$(id -u):$(id -g)" \
		localhost/fedora-desktop-bootc:latest
}

sudo rm -rf "${root}/output"
build_type qcow2 "${root}/output/qcow2-build"
build_type iso "${root}/output/iso-build"

mapfile -d '' qcow2s < <(find "${root}/output/qcow2-build" -type f -name '*.qcow2' -print0)
if ((${#qcow2s[@]} == 0)); then
	echo "error: qcow2 was not produced under ${root}/output/qcow2-build" >&2
	exit 1
fi

mapfile -d '' isos < <(find "${root}/output/iso-build" -type f -name '*.iso' -print0)
if ((${#isos[@]} == 0)); then
	echo "error: ISO was not produced under ${root}/output/iso-build" >&2
	exit 1
fi

# The installer ISO hardcodes a 60s GRUB menu. Replace it in place with 5s.
# The new text is the same length, so the ISO9660 layout stays valid.
shorten_iso_grub_timeout() {
	python3 - "$1" <<'PY'
import mmap
import sys
from pathlib import Path

path = Path(sys.argv[1])
old = b"set timeout=60"
new = b"set timeout=5 "
if len(old) != len(new):
    raise SystemExit("replacement length mismatch")
with path.open("r+b") as handle:
    mapping = mmap.mmap(handle.fileno(), 0)
    start = 0
    count = 0
    while True:
        found = mapping.find(old, start)
        if found < 0:
            break
        mapping[found:found + len(old)] = new
        count += 1
        start = found + len(old)
    already = mapping.find(new)
    mapping.flush()
    mapping.close()
if count == 0 and already < 0:
    raise SystemExit(f"error: {path} has no GRUB timeout to shorten")
print(f"grub timeout 5s ({count} updated): {path}")
PY
}

for iso in "${isos[@]}"; do
	shorten_iso_grub_timeout "${iso}"
done

mkdir -p "${root}/output/qcow2"
mv "${qcow2s[0]}" "${root}/output/qcow2/disk.qcow2"

echo "qcow2: ${root}/output/qcow2/disk.qcow2"
printf 'iso: %s\n' "${isos[@]}"
