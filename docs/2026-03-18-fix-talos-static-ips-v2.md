# 2026-03-18: Fix Talos Static IP and Proxmox Deprecation Warnings

## Overview
Fixed an issue where Talos nodes were not picking up static IP configurations from Cloud-Init snippets, and resolved Proxmox provider deprecation warnings related to CD-ROM configuration.

## Rationale
- **Static IPs**: The previous configuration had an interface conflict on `ide2` between the ISO and the Cloud-Init drive. By explicitly setting the Cloud-Init drive to `ide0`, and using the `nocloud` initialization type, Talos can now successfully find and read the configuration. Additionally, the network interface name was updated to `enp0s18` to match the default for `virtio` on `q35` machine types.
- **Deprecation Warnings**: The `muhlba91/pulumi-proxmoxve` provider (v6) deprecated the `enabled` attribute within the `cdrom` block. The ISOs were originally moved to `disks` but that caused QEMU to fail to boot (exit code 1). They have been moved back to the `cdrom` block, with the deprecated `enabled: true` attribute simply removed.

## Changes
- **Pulumi (`talos.go`)**:
    - Restored Talos ISO to the `cdrom` block but removed the `enabled` property.
    - Updated `Initialization` block to use `interface: ide0`, `type: nocloud`, and added `ipConfigs` for static IP assignment at the Proxmox level.
    - Updated `ConfigPatches` to use `enp0s18` as the network interface name.
    - Ensured `cdrom` is in the `IgnoreChanges` array.
- **Pulumi (`truenas.go`)**:
    - Reverted changes to TrueNAS VM and added `pulumi.Protect(true)` to prevent its destruction or replacement. The deprecation warning will persist to maintain stability.

## Verification
- CI Validation: Monitor the `Pulumi Preview` run for this PR. TrueNAS should now show as `unchanged` (plus protection) and any replacement would fail.
- Logs: Check for the absence of `verification warning` for Talos VMs, but expect it to remain for TrueNAS.
    - Moved TrueNAS ISO to the `disks` array with `interface: ide2`.
    - Removed `cdrom` block and updated `IgnoreChanges`.

## Verification
- CI Validation: Monitor the next `Pulumi Up` run on `main`. The VMs should boot with correct static IPs and the bootstrap process should succeed.
- Logs: Check for the absence of `verification warning: Remove this attribute's configuration as it is no longer used`.

## Pull Request
[Pending]
