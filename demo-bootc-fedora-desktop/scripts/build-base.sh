#!/usr/bin/env bash
# Build the bootc desktop base image (GNOME kiosk, no videos).
# Usage: ./scripts/build-base.sh [image-name]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

default_image="localhost/fedora-desktop-bootc-base:latest"
image="${1:-${default_image}}"

sudo podman build \
	-t "${image}" \
	-f Containerfile \
	.

echo "base image: ${image}"
echo "Next: put videos into ${root}/videos/ and run:"
if [[ "${image}" == "${default_image}" ]]; then
	echo "  ./scripts/build-images.sh qcow2"
	echo "  ./scripts/build-images.sh iso"
else
	echo "  ./scripts/build-images.sh qcow2 --base ${image}"
	echo "  ./scripts/build-images.sh iso --base ${image}"
fi
