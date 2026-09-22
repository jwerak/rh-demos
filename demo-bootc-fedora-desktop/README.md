# Fedora bootc desktop

Fedora 44 GNOME desktop built from a bootc container. After graphical login the session plays every file in `videos/` fullscreen, in a loop.

The same desktop is on both artifacts:

- an Anaconda ISO whose first boot runs an unattended kickstart (wipe the first disk, install, reboot)
- a qcow2 disk for libvirt on this machine

## Prerequisites

- podman
- root, for `podman build` and `bootc-image-builder` (they share `/var/lib/containers/storage`)
- libvirt, `virt-install`, and OVMF (`edk2-ovmf`) to test the qcow2

## Videos

Put at least one `.mp4`, `.mkv`, `.webm`, `.mov`, `.avi`, or `.m4v` file in `videos/` before building. Those files are copied to `/usr/local/share/videos` in the image. Media files are gitignored.

## Build

```bash
./scripts/build-images.sh
```

The image builder cannot emit an ISO and a qcow2 in one request, so the script builds the disk first and the ISO second. Kickstart config is applied only to the ISO.

Outputs:

- `output/qcow2/disk.qcow2`
- an ISO under `output/` (path printed at the end of the script)

The ISO kickstart is Czech (`cs_CZ`, keyboard `cz`, `Europe/Prague`), uses DHCP, and erases the first disk. Boot it only on a disk you can wipe.

## Libvirt

```bash
./scripts/run-libvirt.sh        # boot the preinstalled qcow2
./scripts/run-libvirt.sh iso    # install from the ISO with the embedded kickstart
```

`qcow2` starts VM `fedora-desktop-bootc` from `output/qcow2/disk.qcow2` (4 vCPU, 4 GiB RAM, UEFI, SPICE).

`iso` starts a second VM, `fedora-desktop-bootc-install`. It boots `output/iso-build/bootiso/install.iso` and installs onto a new 20 GiB disk at `output/install/disk.qcow2`. GRUB on the ISO waits 5 seconds, then the kickstart erases that virtual disk, installs, ejects the ISO, and reboots into the desktop. The install does not touch the host disk or the prebuilt qcow2.

GDM logs in as `kiosk` (password `kiosk`) and starts the video loop. Closing mpv starts it again after one second.
