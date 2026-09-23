#!/usr/bin/env bash
# Build the final image with videos/, then an ISO or a qcow2 disk.
# Usage: ./scripts/build-images.sh {iso|qcow2} [--base IMAGE] [--name IMAGE] [--output PATH]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

default_base="localhost/fedora-desktop-bootc-base:latest"
default_final="localhost/fedora-desktop-bootc:latest"
base_image="${BASE_IMAGE:-${default_base}}"
final_image="${FINAL_IMAGE:-${default_final}}"
output_path=""
image_type=""

usage() {
	echo "usage: $0 {iso|qcow2} [--base IMAGE] [--name IMAGE] [--output PATH]" >&2
	echo >&2
	echo "Options:" >&2
	echo "  --base IMAGE    base container to build from (default: ${default_base})" >&2
	echo "  --name IMAGE    tag for the final container with videos (default: ${default_final})" >&2
	echo "  --output PATH   resulting disk artifact (.qcow2 or .iso)" >&2
	echo "                  defaults: output/qcow2/disk.qcow2 or output/iso/install.iso" >&2
	echo >&2
	echo "Build the base image first:" >&2
	echo "  ./scripts/build-base.sh" >&2
	echo "  ./scripts/build-base.sh registry.example.com/fedora-desktop-bootc-base:1.0" >&2
	echo >&2
	echo "Add videos, then build one artifact:" >&2
	echo "  cp /path/to/clip.mp4 videos/" >&2
	echo "  $0 qcow2" >&2
	echo "  $0 iso --base registry.example.com/fedora-desktop-bootc-base:1.0 \\" >&2
	echo "         --name registry.example.com/fedora-desktop-bootc:1.0 \\" >&2
	echo "         --output ./install.iso" >&2
	exit 1
}

require_value() {
	local flag="$1"
	local value="${2:-}"
	if [[ -z "${value}" ]]; then
		echo "error: ${flag} requires a value" >&2
		usage
	fi
}

while (($# > 0)); do
	case "$1" in
	iso | qcow2)
		if [[ -n "${image_type}" ]]; then
			usage
		fi
		image_type="$1"
		shift
		;;
	--base)
		require_value --base "${2:-}"
		base_image="$2"
		shift 2
		;;
	--base=*)
		base_image="${1#--base=}"
		require_value --base "${base_image}"
		shift
		;;
	--name)
		require_value --name "${2:-}"
		final_image="$2"
		shift 2
		;;
	--name=*)
		final_image="${1#--name=}"
		require_value --name "${final_image}"
		shift
		;;
	--output)
		require_value --output "${2:-}"
		output_path="$2"
		shift 2
		;;
	--output=*)
		output_path="${1#--output=}"
		require_value --output "${output_path}"
		shift
		;;
	-h | --help)
		usage
		;;
	*)
		usage
		;;
	esac
done

if [[ -z "${image_type}" ]]; then
	usage
fi

case "${image_type}" in
qcow2)
	default_output="${root}/output/qcow2/disk.qcow2"
	;;
iso)
	default_output="${root}/output/iso/install.iso"
	;;
esac
output_path="${output_path:-${OUTPUT:-${default_output}}}"

if [[ "${output_path}" != /* ]]; then
	output_path="${root}/${output_path}"
fi

case "${image_type}" in
qcow2)
	if [[ "${output_path}" != *.qcow2 && "${output_path}" != *.QCOW2 ]]; then
		echo "error: --output for qcow2 must end with .qcow2 (got ${output_path})" >&2
		exit 1
	fi
	;;
iso)
	if [[ "${output_path}" != *.iso && "${output_path}" != *.ISO ]]; then
		echo "error: --output for iso must end with .iso (got ${output_path})" >&2
		exit 1
	fi
	;;
esac

mapfile -d '' videos < <(find videos -type f \
	\( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' \
		-o -iname '*.mov' -o -iname '*.avi' -o -iname '*.m4v' \) \
	-print0)

if ((${#videos[@]} == 0)); then
	echo "error: put at least one video (mp4, mkv, webm, mov, avi, m4v) into ${root}/videos" >&2
	echo "example: cp /path/to/demo.mp4 ${root}/videos/" >&2
	exit 1
fi

if ! sudo podman image exists "${base_image}"; then
	echo "error: missing base image ${base_image}." >&2
	echo "Run ./scripts/build-base.sh [${base_image}] or pass --base IMAGE." >&2
	exit 1
fi

echo "base image: ${base_image}"
echo "final image: ${final_image}"
echo "output: ${output_path}"

sudo podman build \
	-t "${final_image}" \
	-f Containerfile.videos \
	--ignorefile .containerignore.videos \
	--build-arg "BASE_IMAGE=${base_image}" \
	.

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

build_artifact() {
	local dest="$1"
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
		"${final_image}"
}

mkdir -p "$(dirname "${output_path}")"

case "${image_type}" in
qcow2)
	dest="${root}/output/qcow2-build"
	sudo rm -rf "${dest}"
	build_artifact "${dest}"
	mapfile -d '' qcow2s < <(find "${dest}" -type f -name '*.qcow2' -print0)
	if ((${#qcow2s[@]} == 0)); then
		echo "error: qcow2 was not produced under ${dest}" >&2
		exit 1
	fi
	mv -f "${qcow2s[0]}" "${output_path}"
	echo "qcow2: ${output_path}"
	;;
iso)
	dest="${root}/output/iso-build"
	sudo rm -rf "${dest}"
	build_artifact "${dest}"
	mapfile -d '' isos < <(find "${dest}" -type f -name '*.iso' -print0)
	if ((${#isos[@]} == 0)); then
		echo "error: ISO was not produced under ${dest}" >&2
		exit 1
	fi
	shorten_iso_grub_timeout "${isos[0]}"
	mv -f "${isos[0]}" "${output_path}"
	echo "iso: ${output_path}"
	;;
esac
