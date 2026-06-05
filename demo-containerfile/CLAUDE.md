# CLAUDE.md

Manifest-driven tar archive approach for copying multiple files into container images using ADD directive auto-extraction.

## Prerequisites

- `podman`

## Key Commands

```bash
./create-archive.sh          # Build main.tar.gz from archive-manifest.txt
./build-and-test.sh          # Build image and run verification (calls create-archive.sh if needed)
podman build -t demo-file-copy:latest -f Containerfile .  # Manual build
podman run --rm demo-file-copy:latest                     # Run verification
podman run --rm -it demo-file-copy:latest /bin/bash       # Interactive exploration
```

## File Structure

- `archive-manifest.txt` - Defines which files from `sample_files/` go into the archive (one path per line, `#` comments supported)
- `create-archive.sh` - Reads manifest, creates `main.tar.gz` from `sample_files/`
- `build-and-test.sh` - End-to-end: creates archive if missing, builds image, runs verification
- `Containerfile` - UBI9-based; uses `ADD main.tar.gz /` to extract and merge files into container filesystem
- `main.tar.gz` - Generated artifact (not checked in), consumed by Containerfile
- `sample_files/` - Source files mirroring target filesystem layout (`opt/`, `etc/`)

## How It Works

1. `archive-manifest.txt` lists paths relative to `sample_files/`
2. `create-archive.sh` packs those paths into `main.tar.gz` preserving directory structure
3. `ADD main.tar.gz /` in Containerfile auto-extracts and **merges** with existing container filesystem (does not overwrite `/etc/passwd` etc.)

## Modifying the Demo

Edit `archive-manifest.txt` to add/remove files, place corresponding files under `sample_files/`, then re-run `./create-archive.sh`.
