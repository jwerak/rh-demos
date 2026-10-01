# demo-podman-build-push-run

Canonical agent context for this directory. Cursor and Antigravity read `AGENTS.md`. `CLAUDE.md` is a symlink to this file for Claude Code.

## Overview

Minimal Podman build/push/run demo. Builds an httpd container from UBI8 serving a static page.

## Files

- `Dockerfile` - UBI8 + httpd, serves a single HTML page on port 80
- `README.md` - Usage instructions

## Commands

```bash
podman build -t quay.io/jwerak/hello-web .
podman push quay.io/jwerak/hello-web
podman run --name hello-web -d -p 8080:80 quay.io/jwerak/hello-web
```

Test at http://localhost:8080.
