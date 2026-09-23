---
name: bootc-fedora-desktop
description: >-
  Builds and runs the Fedora 44 bootc GNOME desktop demo
  (demo-bootc-fedora-desktop): base container, video-layer image, kickstart
  ISO, libvirt qcow2, and fullscreen mpv video loop. Use when the user asks to
  build, rebuild, or run this demo; mentions bootc desktop, fedora-desktop-bootc,
  kickstart ISO, video kiosk, or run-libvirt for this directory.
---

# Bootc Fedora desktop demo

Work in `demo-bootc-fedora-desktop/`. Read that directory’s `AGENTS.md` first
(symlink: `CLAUDE.md`). Human overview: `README.md`.

Local podman + libvirt only. Not part of `ansible-controller/`.

## Workflow

Copy this checklist and track progress:

```
- [ ] 1. Build base image
- [ ] 2. Place media in videos/
- [ ] 3. Build final image + artifact (iso XOR qcow2)
- [ ] 4. Run under libvirt (optional)
```

### 1. Base image

```bash
./scripts/build-base.sh
# optional: ./scripts/build-base.sh registry.example.com/fedora-desktop-bootc-base:1.0
```

Default tag: `localhost/fedora-desktop-bootc-base:latest`. Needs root/`sudo` so
`bootc-image-builder` later sees the image in the root store.

### 2. Videos

Put at least one clip in `videos/` (mp4, mkv, webm, mov, avi, m4v). Files there
are gitignored except `.gitkeep`. Do not commit media.

### 3. Final image + disk artifact

`bootc-image-builder` cannot emit ISO and qcow2 in one request. Choose one:

```bash
./scripts/build-images.sh qcow2   # -> output/qcow2/disk.qcow2
./scripts/build-images.sh iso     # -> output/iso/install.iso
```

Flags / env: `--base` / `BASE_IMAGE`, `--name` / `FINAL_IMAGE`,
`--output` / `OUTPUT`. Fails if base is missing or `videos/` has no media.

ISO builds patch GRUB timeout 60s → 5s. Kickstart is Czech locale, DHCP, and
**erases the first disk** it boots on.

### 4. Libvirt

```bash
./scripts/run-libvirt.sh        # VM fedora-desktop-bootc from prebuilt qcow2
./scripts/run-libvirt.sh iso    # install VM; disk at output/install/disk.qcow2
```

Expect GDM autologin as `kiosk` / `kiosk` and fullscreen video loop.

## Hard constraints (do not “fix” casually)

| Topic | Keep |
|---|---|
| mpv video output | `--vo=wlshm --hwdec=no` (GPU/Vulkan path crashes in libvirt without a device) |
| video-loop unit | `Restart=always`; enabled under `graphical-session.target.wants` |
| ISO install target | kickstart `%post` must set `graphical.target` (text install otherwise leaves multi-user) |
| GNOME UX | dconf locks + `no-overview@kiosk` extension (hide dash / welcome) |
| Image split | base without videos; `Containerfile.videos` layers media |
| Artifact mix | never ask bib for iso+qcow2 together |

## Agent do’s / don’ts

- Prefer the existing scripts over inventing one-off `podman`/`virt-install` flows.
- Use `podman` / `buildah` / `skopeo`, not docker.
- Do not commit `videos/*` (except `.gitkeep`), `output/`, or secrets.
- Do not point the ISO kickstart at a host disk the user cannot wipe.
- When changing layout or commands, update `AGENTS.md` (and keep `CLAUDE.md` as the symlink).

## Extra detail

- Layout and defaults: `demo-bootc-fedora-desktop/AGENTS.md`
- Diagram: `diagrams/bootc_build_deploy.png` (regen via generate-diagram skill if asked)
