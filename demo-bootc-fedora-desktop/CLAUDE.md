# CLAUDE.md

Fedora 44 bootc GNOME desktop that loops local videos. Local podman and libvirt only; not wired into `ansible-controller/`.

## Prerequisites

- podman
- root for image build (`bootc-image-builder` reads the image from the root container store)
- libvirt, virt-install, edk2-ovmf for the qcow2 test

## Layout

- `Containerfile` — base image from `quay.io/fedora/fedora-bootc:44`: slim GNOME, `mpv`, user `kiosk` / password `kiosk`, GDM autologin, dconf kiosk locks, empty `/usr/local/share/videos`. `config/tmpfiles/kiosk-home.conf` creates `/var/home/kiosk` on boot. Tagged as `localhost/fedora-desktop-bootc-base:latest`.
- `Containerfile.videos` — `FROM` the base image and `COPY videos/` into `/usr/local/share/videos`. Tagged as `localhost/fedora-desktop-bootc:latest`.
- `config/config.toml` — unattended kickstart for the ISO (`text --non-interactive`, wipe first disk, `autopart`, `reboot --eject`). A `%post` forces `graphical.target`, because a text install otherwise writes `multi-user.target` into `/etc` and hides the image default. Disables Anaconda's Users module; the account lives in the image. `bootc-image-builder` adds `ostreecontainer`.
- `config/gdm-custom.conf`, `config/systemd/video-loop.service`, `config/dconf/`, `config/gnome-shell/no-overview@kiosk/` — autologin, one workspace, and a user service `mpv --vo=wlshm --hwdec=no --fullscreen --ontop --loop-playlist=inf` with `Restart=always`. The shell extension closes the overview so the dash stays hidden. Closing mpv starts it again. `wlshm` is software Wayland output; the default GPU output crashes in a libvirt guest without a Vulkan device. The unit is enabled by a symlink in `/usr/lib/systemd/user/graphical-session.target.wants/`.
- `videos/` — inputs for the final image (gitignored except `.gitkeep`).
- `scripts/build-base.sh [image-name]` — builds the base container. Default tag is `localhost/fedora-desktop-bootc-base:latest`.
- `scripts/build-images.sh {iso|qcow2} [--base IMAGE] [--name IMAGE] [--output PATH]` — requires the base image and at least one video, builds `Containerfile.videos`, then one `bootc-image-builder` run (`--rootfs xfs`). Defaults: `--base` `localhost/fedora-desktop-bootc-base:latest` (or `BASE_IMAGE`), `--name` `localhost/fedora-desktop-bootc:latest` (or `FINAL_IMAGE`), `--output` `output/qcow2/disk.qcow2` or `output/iso/install.iso` (or `OUTPUT`). ISO builds rewrite the hardcoded 60s GRUB timeout to 5s.
- `scripts/run-libvirt.sh` — `qcow2` (default) imports `output/qcow2/disk.qcow2` as `fedora-desktop-bootc`. `iso` boots `output/iso/install.iso` as `fedora-desktop-bootc-install` and lets the embedded kickstart install onto `output/install/disk.qcow2` (20 GiB, created on first use). `--os-variant fedora43` matches the newest Fedora guest profile in osinfo on this host.

## Commands

```bash
./scripts/build-base.sh
# ./scripts/build-base.sh registry.example.com/fedora-desktop-bootc-base:1.0
cp /path/to/clip.mp4 videos/
./scripts/build-images.sh qcow2
./scripts/build-images.sh qcow2 \
  --base registry.example.com/fedora-desktop-bootc-base:1.0 \
  --name registry.example.com/fedora-desktop-bootc:1.0 \
  --output ./demo-desktop.qcow2
./scripts/build-images.sh iso
./scripts/run-libvirt.sh
./scripts/run-libvirt.sh iso
```

The ISO kickstart erases the first disk it boots on.
