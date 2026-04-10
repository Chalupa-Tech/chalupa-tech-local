# 2026-04-10: GPU Passthrough Host Prep (Strix Halo iGPU)

## Overview
Configures the Proxmox host to bind the AMD Strix Halo iGPU (`0000:c7:00.0`, `1002:1586`) and its HD Audio function (`0000:c7:00.1`, `1002:1640`) to `vfio-pci` at boot, enabling GPU passthrough to the Plex VM for hardware-accelerated transcoding.

This is PR 1 of 2. PR 2 will add the actual GPU passthrough config to the Plex VM (Pulumi) and install VA-API drivers (Ansible). The split is necessary because the host must be rebooted after these kernel/modprobe changes take effect, and that reboot must happen before Pulumi tries to start the VM with GPU passthrough enabled.

## Rationale
GPU passthrough was originally added in PR #28 and removed in PR #32 because `qm start` hung indefinitely. The Strix Halo iGPU only supports `pm`/`bus` reset (no FLR), and without specific host-level workarounds, the GPU can't be cleanly handed from host drivers to `vfio-pci`.

A [Level1Techs guide](https://forum.level1techs.com/t/how-to-setup-proxmox-9-with-gpu-passthrough-to-an-ubuntu-25-vm-to-use-ollama-steam-on-strix-halo-max-395/239880) proves passthrough works on the same hardware (Strix Halo) and kernel (6.17) with three host-level changes:

1. **Blacklist `amdgpu`, `radeon`, `snd_hda_intel`** so no host driver claims the GPU at boot.
2. **Bind `1002:1586,1002:1640` to `vfio-pci` with `disable_vga=1`** via modprobe options + softdeps so `vfio-pci` loads before any GPU driver.
3. **Add `initcall_blacklist=sysfb_init`** to the kernel command line to prevent the system framebuffer from reserving GPU memory during early boot (which would block `vfio-pci` from claiming the device).

## Changes
- **Ansible defaults** `ansible/roles/proxmox_prep/defaults/main.yml`: Added `proxmox_prep_gpu_passthrough_enabled`, `proxmox_prep_gpu_vfio_ids`, and `proxmox_prep_gpu_blacklist_drivers` variables. All new tasks are guarded by `when: proxmox_prep_gpu_passthrough_enabled`.
- **Ansible tasks** `ansible/roles/proxmox_prep/tasks/main.yml`: Added three tasks:
  - Write `/etc/modprobe.d/blacklist-gpu.conf` (blacklists amdgpu, radeon, snd_hda_intel)
  - Write `/etc/modprobe.d/vfio-pci.conf` (vfio-pci ids + disable_vga=1 + softdeps)
  - Append `initcall_blacklist=sysfb_init` to GRUB command line

## Post-Merge Steps
After this PR merges and the deploy pipeline runs:
1. SSH to pve1 and verify the files were written correctly
2. **Reboot the Proxmox host** (`reboot`)
3. Verify VFIO bindings after reboot: `lspci -nnk -s c7:00.0` should show `Kernel driver in use: vfio-pci`
4. Verify both VMs (TrueNAS + Plex) are still running: `qm list`

## Pull Request
[PR #41](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/41)
