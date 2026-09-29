# Fedora Silverblue 44 libvirt demo

Canonical agent context for `demo-fedora-silverblue/`. `CLAUDE.md` is a symlink to this file.

Unattended install of official Fedora Silverblue 44 in a local libvirt guest, then a reproduction of [Déjà Dup issue 670](https://gitlab.gnome.org/World/deja-dup/-/work_items/670): the Flathub Flatpak can list a restic repo, but browse/restore fails because `fusermount` is missing or blocked in the sandbox.

Local libvirt only. Not wired into `ansible-controller/`.

For install and repro workflows, prefer the project skill `fedora-silverblue`.

## Prerequisites

- libvirt, `virt-install`, and OVMF (`edk2-ovmf`)
- `curl`, `ssh`, `ssh-keygen`
- The host libvirt `default` NAT network
- `--os-variant silverblue43` matches the newest Silverblue guest profile in osinfo on this host

## Layout

- `config/silverblue.ks` — unattended kickstart. Czech locale (`cs_CZ`, keyboard `cz`, `Europe/Prague`), DHCP, user `demo` / password `demo`, locked root, SSH, GDM autologin. `clearpart` and `ignoredisk --only-use=vda` wipe only the virtio system disk. `ostreesetup` installs `fedora/44/x86_64/silverblue` from `file:///ostree/repo` on the ISO. `%post` writes the demo SSH public key (placeholder `__DEMO_SSH_PUBKEY__`), skips GNOME Initial Setup, and forces `graphical.target`.
- `scripts/download-iso.sh` — downloads `Fedora-Silverblue-ostree-x86_64-44-1.7.iso` (volume label `Fedora-SB-ostree-x86_64-44`) into `output/iso/` and checks SHA256.
- `scripts/run-libvirt.sh` — generates `output/ssh/id_ed25519` if needed, renders `output/silverblue.ks`, and `virt-install`s VM `fedora-silverblue-44` onto a new 40 GiB `output/install/disk.qcow2`. Kernel and initrd come from `images/pxeboot/` inside the ISO. Extra kernel args: `inst.ks=file:/silverblue.ks`, `inst.stage2` and `inst.repo` on `hd:LABEL=Fedora-SB-ostree-x86_64-44`. The graphical console must stay open until Anaconda reboots. virt-install uses that reboot to remove the installer kernel from the domain and boot the disk. Closing it early leaves the next start on the installer, and the kickstart will wipe `vda` again.
- `scripts/guest-repro.sh` — guest-side repro. Records host `fusermount`/`fusermount3`/`/dev/fuse`, installs Flathub `org.gnome.DejaDup`, probes the sandbox and `flatpak-spawn --host`, creates a local restic repo, lists snapshots, then runs `restic mount` (the GUI browse path).
- `scripts/reproduce-fusermount.sh` — waits for the guest DHCP lease, SSH, and `/run/user/<uid>/bus`, pipes `guest-repro.sh` over SSH, and copies the log to `output/fusermount-repro.log`.
- `output/` — ISO, disk, SSH key, rendered kickstart, repro log. Gitignored.

## Commands

```bash
./scripts/download-iso.sh
./scripts/run-libvirt.sh
./scripts/reproduce-fusermount.sh
```

`run-libvirt.sh` opens the graphical console and blocks until that window closes. Run the repro from another terminal after the guest has rebooted to the desktop.

The kickstart erases virtual disk `vda` only. It does not touch the host disk.

## Issue 670

Environment to match: Fedora Silverblue 44, Déjà Dup from Flathub (report used 50.1), restic backend, local folder repo.

What the report shows: `restic snapshots` succeeds inside the Flatpak. Browse/restore then fails while mounting because `fusermount` (or `/dev/fuse`) is unavailable in the sandbox. Flatpak refuses to share host `/usr` into the sandbox (`/usr` is reserved). Déjà Dup's wrapper is supposed to call the host binary via `flatpak-spawn --host`, which needs the user session bus and `--talk-name=org.freedesktop.Flatpak`.

Verified on this guest with Fedora Flatpak `org.gnome.DejaDup` 50.1 (`org.fedoraproject.Platform` f44), not Flathub. Two missing permissions:

1. No `org.freedesktop.Flatpak=talk`, so `flatpak-spawn --host` fails and the wrapper reports `fusermount not found`.
2. No `xdg-run/deja-dup:create`, so the mount point exists only inside the sandbox and host `fusermount3` returns `No such file or directory` for `/run/user/<uid>/deja-dup/restic/<id>`.

```bash
flatpak override --user --talk-name=org.freedesktop.Flatpak org.gnome.DejaDup
flatpak override --user --filesystem=xdg-run/deja-dup:create org.gnome.DejaDup
```

GUI check after the script, on the guest console: open Déjà Dup, back up a local folder, then Browse or Restore. For the same trace as the report:

```bash
DEJA_DUP_DEBUG=1 flatpak run org.gnome.DejaDup
```
