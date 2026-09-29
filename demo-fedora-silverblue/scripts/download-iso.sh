#!/usr/bin/env bash
# Download the official Fedora Silverblue 44 ostree ISO and verify SHA256.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
iso_name="Fedora-Silverblue-ostree-x86_64-44-1.7.iso"
iso_url="https://download.fedoraproject.org/pub/fedora/linux/releases/44/Silverblue/x86_64/iso/${iso_name}"
iso_sha256="9ccec9b075a0a4358a7209b2667156aaeeec3a6a3c8d71cada45b57fca9b4682"
dest="${root}/output/iso/${iso_name}"

mkdir -p "${root}/output/iso"

if [[ -f "${dest}" ]]; then
	echo "Found ${dest}, verifying SHA256."
else
	echo "Downloading ${iso_url}"
	curl -fL --continue-at - -o "${dest}" "${iso_url}"
fi

echo "${iso_sha256}  ${dest}" | sha256sum -c -
echo "ISO ready: ${dest}"
