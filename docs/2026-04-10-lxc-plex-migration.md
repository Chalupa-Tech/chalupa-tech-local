# Plex VM → LXC Migration

**PR**: (link after creation)

## Overview

Migrates Plex Media Server from a Fedora 43 VM (VMID 200) to an Ubuntu 24.04 LTS LXC container with GPU sharing via `/dev/dri` device passthrough.

## Rationale

The primary goal is **GPU sharing** — allowing the Strix Halo iGPU to be used by multiple containers (and the host) simultaneously, rather than exclusively locking it to one VM via VFIO passthrough.

LXC GPU sharing works by bind-mounting `/dev/dri/renderD128` and `/dev/dri/card0` into the container, with the `amdgpu` driver loaded on the host. This is lighter weight than a full VM and avoids the FLR/reset issues that plagued VM GPU passthrough on Strix Halo (PR #28 added, PR #32 removed).

## Changes

### Pulumi
- **Deleted** `plex.go` (Fedora VM definition)
- **Created** `plex_lxc.go` — `ct.NewContainer` with:
  - Ubuntu 24.04 LTS, 8 cores, 8GB RAM, 16GB disk
  - GPU: `/dev/dri/renderD128` + `/dev/dri/card0` device passthrough
  - Static IP 192.168.1.224/24, boot order 3, unprivileged
  - Nesting enabled (systemd), NFS mount support
- **Updated** `main.go` — `createPlexVM()` → `createPlexLXC()`

### Ansible
- **Rewrote** `roles/plex_server/` for Ubuntu:
  - `dnf` → `apt`, `nfs-utils` → `nfs-common`, `wheel` → `sudo`
  - RPM repo → DEB repo (`downloads.plex.tv/repo/deb`)
  - `firewalld` → `ufw`
  - Removed `qemu-guest-agent` (not needed in LXC)
  - Added VA-API drivers (`mesa-va-drivers`, `libva2`, `vainfo`)
  - Added `plex` user to `video` + `render` groups for GPU access
- **Updated** `inventory-vms.yml` — `ansible_user: fedora` → `root`
- **Updated** `playbooks/vm-configure.yml` — removed `gather_facts: false` workaround

### CI/CD
- Stage 2 comment updated for LXC
- Stage 3 inventory generation: `ansible_user: root`

## Pre-Merge Manual Steps

See `docs/superpowers/specs/2026-04-10-kernel7-lxc-gpu-migration-design.md` for the full cutover procedure (backup Plex data, destroy old VM, Pulumi state delete).

## Post-Merge Verification

1. SSH to `root@192.168.1.224`
2. `systemctl status plexmediaserver` → running
3. `vainfo` → AMD VA-API device recognized
4. `mount | grep nfs` → TrueNAS shares mounted
5. Plex UI at `192.168.1.224:32400/web` → accessible
6. Play video requiring transcode → "(hw)" indicator in dashboard
