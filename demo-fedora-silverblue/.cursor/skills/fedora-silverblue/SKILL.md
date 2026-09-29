---
name: fedora-silverblue
description: >-
  Installs official Fedora Silverblue 44 in a libvirt VM
  (demo-fedora-silverblue) and reproduces Déjà Dup issue 670: Flathub
  Flatpak restic browse/restore fails because fusermount is missing or
  blocked. Use when the user asks to install Silverblue 44, run this
  demo, or reproduce the Déjà Dup restic fusermount mount failure.
---

# Fedora Silverblue 44 demo

Work in `demo-fedora-silverblue/`. Read that directory’s `AGENTS.md` first
(symlink: `CLAUDE.md`). Human overview: `README.md`.

Local libvirt only. Not part of `ansible-controller/`.

## Workflow

Copy this checklist and track progress:

```
- [ ] 1. Download the official Silverblue 44 ISO
- [ ] 2. Install the VM with the kickstart
- [ ] 3. Run the fusermount repro after the desktop is up
```

### 1. ISO

```bash
./scripts/download-iso.sh
```

Writes `output/iso/Fedora-Silverblue-ostree-x86_64-44-1.7.iso` and checks
SHA256. Volume label: `Fedora-SB-ostree-x86_64-44`.

### 2. Libvirt install

```bash
./scripts/run-libvirt.sh
```

VM name `fedora-silverblue-44`. Disk `output/install/disk.qcow2` (40 GiB,
created on first use). Generates `output/ssh/id_ed25519` and renders
`output/silverblue.ks`. Graphical console blocks until closed.

Expect GDM autologin as `demo` / `demo`. The kickstart wipes virtual disk
`vda` only.

### 3. Issue 670 repro

From another terminal, after the guest has rebooted to the desktop:

```bash
./scripts/reproduce-fusermount.sh
```

Log: `output/fusermount-repro.log`.

What “reproduced” looks like: `restic snapshots` succeeds, `restic mount`
fails, and the log shows `fusermount` missing in the sandbox and/or
`flatpak-spawn --host` unable to run host `fusermount3`. GUI equivalent on
the console: Déjà Dup Browse/Restore, or
`DEJA_DUP_DEBUG=1 flatpak run org.gnome.DejaDup`.

Fedora Flatpak 50.1 is missing two permissions that Flathub sets. On the guest:

```bash
flatpak override --user --talk-name=org.freedesktop.Flatpak org.gnome.DejaDup
flatpak override --user --filesystem=xdg-run/deja-dup:create org.gnome.DejaDup
```

## Hard constraints

| Topic | Keep |
|---|---|
| Install source | Official Silverblue 44 ostree ISO, not a bootc image |
| ostree ref | `fedora/44/x86_64/silverblue` from `file:///ostree/repo` |
| Disk wipe | `ignoredisk --only-use=vda` so the ISO and host disks stay intact |
| Flatpak | Flathub `org.gnome.DejaDup`, not the Fedora remote |
| Session bus | Repro must run after GDM autologin so `flatpak-spawn --host` has a user bus |
| os-variant | `silverblue43` until osinfo ships a silverblue44 profile |

## Agent do’s / don’ts

- Prefer the scripts over one-off `virt-install` commands.
- Do not commit `output/` (ISO, disk, SSH key, rendered kickstart, logs).
- Do not point the kickstart at a host disk.
- When changing layout or commands, update `AGENTS.md` (and keep `CLAUDE.md` as the symlink).
