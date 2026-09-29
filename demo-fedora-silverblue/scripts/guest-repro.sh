#!/usr/bin/env bash
# Run inside the Silverblue guest (demo user, graphical session bus up).
# Reproduces GitLab deja-dup#670: Flatpak Déjà Dup / restic mount vs fusermount.
set -euo pipefail

log="${HOME}/fusermount-repro.log"
exec > >(tee "${log}") 2>&1

echo "=== os-release ==="
cat /etc/os-release || true

echo "=== rpm-ostree ==="
rpm-ostree status || true

echo "=== host fuse ==="
command -v fusermount || echo "host fusermount: missing"
command -v fusermount3 || echo "host fusermount3: missing"
ls -l /usr/bin/fusermount /usr/bin/fusermount3 /dev/fuse 2>&1 || true
rpm -q fuse fuse3 2>/dev/null || true

uid="$(id -u)"
export XDG_RUNTIME_DIR="/run/user/${uid}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
if [[ ! -S "${XDG_RUNTIME_DIR}/bus" ]]; then
	echo "error: no session bus at ${XDG_RUNTIME_DIR}/bus (GDM autologin not up yet)" >&2
	exit 1
fi

echo "=== install Flathub Déjà Dup ==="
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y --user flathub org.gnome.DejaDup
flatpak info --user org.gnome.DejaDup || true

echo "=== sandbox fuse and flatpak-spawn ==="
flatpak run --user --command=bash org.gnome.DejaDup -c '
set +e
echo "PATH=${PATH}"
echo "sandbox fusermount: $(command -v fusermount || echo missing)"
echo "sandbox fusermount3: $(command -v fusermount3 || echo missing)"
ls -l /dev/fuse || echo "no /dev/fuse in sandbox"
echo "--- find fusermount under /app ---"
find /app \( -name '*fusermount*' -o -name 'find-fusermount' \) -print 2>/dev/null
echo "--- flatpak-spawn --host ---"
flatpak-spawn --host sh -c "command -v fusermount; command -v fusermount3; ls -l /dev/fuse"
echo "flatpak-spawn exit: $?"
'

repo="${HOME}/restic-repo"
src="${HOME}/restic-src"
mnt="${HOME}/restic-mnt"
rm -rf "${repo}" "${src}" "${mnt}"
mkdir -p "${src}" "${mnt}"
echo "repro $(date -Is)" > "${src}/hello.txt"

echo "=== restic snapshots (expected to succeed) ==="
flatpak run --user --env=RESTIC_PASSWORD=demo --command=restic org.gnome.DejaDup \
	-r "${repo}" init
flatpak run --user --env=RESTIC_PASSWORD=demo --command=restic org.gnome.DejaDup \
	-r "${repo}" backup "${src}"
flatpak run --user --env=RESTIC_PASSWORD=demo --command=restic org.gnome.DejaDup \
	--json -r "${repo}" snapshots

echo "=== restic mount (issue 670: expected to fail) ==="
set +e
timeout 30 flatpak run --user --env=RESTIC_PASSWORD=demo --command=restic org.gnome.DejaDup \
	-r "${repo}" mount "${mnt}"
echo "restic mount exit: $?"
set -e

echo "Log: ${log}"
echo "GUI: open Déjà Dup, back up a local folder with the restic backend, then Browse/Restore."
echo "Debug: DEJA_DUP_DEBUG=1 flatpak run org.gnome.DejaDup"
