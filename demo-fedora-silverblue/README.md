# Fedora Silverblue 44

Unattended libvirt install of official Fedora Silverblue 44, plus a reproduction of [Déjà Dup issue 670](https://gitlab.gnome.org/World/deja-dup/-/work_items/670): Flathub Déjà Dup can list a restic backup, but browse/restore fails because `fusermount` is missing or blocked.

## Prerequisites

- libvirt, `virt-install`, and OVMF (`edk2-ovmf`)
- the libvirt `default` network

## Install

```bash
./scripts/download-iso.sh
./scripts/run-libvirt.sh
```

The kickstart is Czech (`cs_CZ`, keyboard `cz`, `Europe/Prague`), uses DHCP, and erases only the virtual disk `vda`. Login is `demo` / `demo`, with GDM autologin. SSH uses `output/ssh/id_ed25519`.

`run-libvirt.sh` opens the graphical console and stays there until you close it. The ISO volume label is `Fedora-SB-ostree-x86_64-44`.

## Reproduce the fusermount failure

After the guest has rebooted to the desktop, from another terminal:

```bash
./scripts/reproduce-fusermount.sh
```

The script waits for SSH and the autologin session bus, installs Flathub `org.gnome.DejaDup`, records whether `fusermount` / `fusermount3` / `/dev/fuse` exist on the host and inside the sandbox, creates a local restic repo, lists snapshots, and runs `restic mount`. The log is copied to `output/fusermount-repro.log`.

On the guest console, the GUI form of the same bug is: open Déjà Dup, back up a local folder, then Browse or Restore. A debug trace:

```bash
DEJA_DUP_DEBUG=1 flatpak run org.gnome.DejaDup
```

`restic snapshots` succeeding and `restic mount` failing is the failure in issue 670.

On this guest the installed app was Fedora's Flatpak `org.gnome.DejaDup` 50.1, not Flathub. Browse/restore started working after these user overrides:

```bash
flatpak override --user --talk-name=org.freedesktop.Flatpak org.gnome.DejaDup
flatpak override --user --filesystem=xdg-run/deja-dup:create org.gnome.DejaDup
```

The first lets the app run host `fusermount3`. The second puts `/run/user/1000/deja-dup` on the host, where `fusermount3` can see it. Quit Déjà Dup completely after applying them. Remove with `flatpak override --user --reset org.gnome.DejaDup`.
