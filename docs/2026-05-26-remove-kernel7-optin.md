# Remove Kernel 7 Opt-In from Proxmox Prep

- **Date:** 2026-05-26
- **PR:** TBD
- **Related:** `docs/2026-04-10-kernel7-lxc-host-prep.md`

## Summary

Drop the four `proxmox_prep_kernel_7_enabled` tasks and the
`proxmox_prep_kernel_7_enabled` default from the `proxmox_prep` role. The
host is being upgraded to an official Proxmox release that ships Linux
kernel 7 by default, so the `pve-test` repo opt-in is no longer needed.

## Why

The original kernel 7 opt-in (PR for `2026-04-10-kernel7-lxc-host-prep.md`)
was a temporary measure to get better AMD Strix Halo iGPU support before
kernel 7 became the default. As called out in that doc, kernel 7 is the
default in PVE 9.2 — so once the host runs the official 9.2 release, the
`pve-test` repo + `proxmox-kernel-7.0` install + `proxmox-boot-tool kernel
pin` tasks become dead weight at best, and a risk at worst (the `pve-test`
repo would keep pulling unstable point releases).

Pinning a specific kernel via `proxmox-boot-tool kernel pin` also prevents
the host from picking up newer kernels delivered by the official repo,
which is the opposite of what we want post-upgrade.

## Changes

- `ansible/roles/proxmox_prep/tasks/main.yml` — remove the four kernel 7
  tasks (enable `pve-test` repo, install `proxmox-kernel-7.0`, find
  installed version, pin as default).
- `ansible/roles/proxmox_prep/defaults/main.yml` — remove the
  `proxmox_prep_kernel_7_enabled` flag.
- `CLAUDE.md`, `README.md`, `.github/workflows/deploy.yml` — drop the
  "kernel 7" mentions from the Stage 1 descriptions.

The IOMMU / VFIO / GRUB / systemd-boot tasks are unchanged — those are
unrelated to the kernel 7 opt-in and still required.

## Manual Step (out of band)

Before merging, the Proxmox host should be upgraded to the official PVE
release with kernel 7 as default. The host's `pve-test` apt source
(`/etc/apt/sources.list.d/pve-test.list`) and any pinned kernel (via
`proxmox-boot-tool kernel pin`) should be removed manually:

```bash
# On the Proxmox host
rm -f /etc/apt/sources.list.d/pve-test.list
proxmox-boot-tool kernel unpin
proxmox-boot-tool refresh
```

Ansible's `apt_repository` module with `state: present` only adds repos —
removing the file when the flag is dropped is not idempotent in code, so
the cleanup is intentionally manual.
