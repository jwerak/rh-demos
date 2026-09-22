# CLAUDE.md

Fedora 44 bootc GNOME desktop that loops local videos. Local podman and libvirt only; not wired into `ansible-controller/`.

## Prerequisites

- podman
- root for image build (`bootc-image-builder` reads the image from the root container store)
- libvirt, virt-install, edk2-ovmf for the qcow2 test

## Layout

- `Containerfile` — `quay.io/fedora/fedora-bootc:44`, slim GNOME, `mpv`, user `kiosk` / password `kiosk`, GDM autologin, dconf kiosk locks. Videos are copied to `/usr/local/share/videos` because bootc does not deploy `/var` from the image. `config/tmpfiles/kiosk-home.conf` creates `/var/home/kiosk` on boot.
- `config/config.toml` — unattended kickstart for the ISO (`text --non-interactive`, wipe first disk, `autopart`, `reboot --eject`). A `%post` forces `graphical.target`, because a text install otherwise writes `multi-user.target` into `/etc` and hides the image default. Disables Anaconda's Users module; the account lives in the image. `bootc-image-builder` adds `ostreecontainer`.
- `config/gdm-custom.conf`, `config/systemd/video-loop.service`, `config/dconf/`, `config/gnome-shell/no-overview@kiosk/` — autologin, one workspace, and a user service `mpv --vo=wlshm --hwdec=no --fullscreen --ontop --loop-playlist=inf` with `Restart=always`. The shell extension closes the overview so the dash stays hidden. Closing mpv starts it again. `wlshm` is software Wayland output; the default GPU output crashes in a libvirt guest without a Vulkan device. The unit is enabled by a symlink in `/usr/lib/systemd/user/graphical-session.target.wants/`.
- `videos/` — build inputs (gitignored except `.gitkeep`).
- `scripts/build-images.sh` — fails when `videos/` has no media, then `sudo podman build` and two `quay.io/centos-bootc/bootc-image-builder` runs (`--type qcow2`, then `--type iso` with the kickstart). One request cannot mix an ISO and a disk image. `--rootfs xfs`. Final disk path is `output/qcow2/disk.qcow2`.
- `scripts/run-libvirt.sh` — `qcow2` (default) imports `output/qcow2/disk.qcow2` as `fedora-desktop-bootc`. `iso` boots `install.iso` as `fedora-desktop-bootc-install` and lets the embedded kickstart install onto `output/install/disk.qcow2` (20 GiB, created on first use). `--os-variant fedora43` matches the newest Fedora guest profile in osinfo on this host. The ISO GRUB menu waits 5s before the kickstart entry. `build-images.sh` rewrites the builder's hardcoded 60s timeout in place.

## Commands

```bash
./scripts/build-images.sh
./scripts/run-libvirt.sh
./scripts/run-libvirt.sh iso
```

The ISO kickstart erases the first disk it boots on.
