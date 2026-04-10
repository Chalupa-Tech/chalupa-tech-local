# Kernel 7 Upgrade + LXC Host Prep

**PR**: (link after creation)

## Overview

Prepares the Proxmox host for LXC-based GPU sharing by:

1. Disabling VFIO GPU passthrough (cleanup from abandoned `feat/gpu-passthrough-host-prep`)
2. Upgrading to Linux kernel 7.0 via `pve-test` repo (better Strix Halo iGPU support)
3. Downloading the Ubuntu 24.04 LTS container template for the upcoming Plex LXC migration

## Rationale

GPU passthrough to the Plex VM was attempted (PR #28) and removed (PR #32) because `qm start` hung — the Strix Halo iGPU only supports pm/bus reset, not FLR. The VFIO approach (`feat/gpu-passthrough-host-prep`) was designed to work around this, but the actual goal is **GPU sharing** across multiple containers, not exclusive passthrough to a single VM.

LXC GPU sharing requires the `amdgpu` driver loaded on the host (bind-mounting `/dev/dri/renderD128` into containers). This is incompatible with VFIO, which blacklists `amdgpu` and binds the GPU to `vfio-pci`. Therefore, the VFIO approach is abandoned in favor of LXC GPU sharing.

Kernel 7.0 (opt-in for PVE 9, default in 9.2) improves AMD Strix Halo support. It is available from the `pve-test` repository.

## Changes

- `ansible/roles/proxmox_prep/defaults/main.yml`: Added `proxmox_prep_gpu_passthrough_enabled: false`, `proxmox_prep_kernel_7_enabled`, and LXC template variables
- `ansible/roles/proxmox_prep/tasks/main.yml`:
  - VFIO cleanup: removes stale `blacklist-gpu.conf`, `vfio-pci.conf`, and `initcall_blacklist` from GRUB
  - Kernel 7: enables `pve-test` repo, installs `proxmox-kernel-7.0`, pins as default
  - LXC template: downloads Ubuntu 24.04 LTS container template via `pveam`

## Post-Merge Verification

1. SSH to `pve1` and **reboot** the host
2. Verify kernel: `uname -r` should show 7.x
3. Verify GPU driver: `lspci -nnk -s c7:00.0` should show `Kernel driver in use: amdgpu`
4. Verify render device: `ls /dev/dri/renderD128` should exist
5. Verify VMs: `qm list` should show both VMs running
6. Verify template: `pveam list local` should show Ubuntu 24.04 template

## Next Steps

PR B will create the Plex LXC container, rewrite the Ansible role for Ubuntu, and handle the VM-to-LXC cutover. See `docs/superpowers/specs/2026-04-10-kernel7-lxc-gpu-migration-design.md` for the full migration spec.
