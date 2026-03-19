# 2026-03-18: Fix Talos Static IP and Proxmox Deprecation Warnings

## Overview
Fixed an issue where Talos nodes were not picking up static IP configurations from Cloud-Init snippets, and resolved Proxmox provider deprecation warnings related to CD-ROM configuration.

## Rationale
- **Static IPs**: The previous configuration had an interface conflict on `ide2` between the ISO and the Cloud-Init drive. By explicitly setting the ISO to `ide2` and the Cloud-Init drive to `ide0`, and using the `nocloud` initialization type, Talos can now successfully find and read the configuration. Additionally, the network interface name was updated to `enp0s18` to match the default for `virtio` on `q35` machine types.
- **Deprecation Warnings**: The `muhlba91/pulumi-proxmoxve` provider (v6) deprecated the top-level `cdrom` block in favor of defining ISOs within the `disks` array. This was updated for all VMs (Talos and TrueNAS).

## Changes
- **Pulumi (`talos.go`)**:
    - Moved Talos ISO to the `disks` array with `interface: ide2`.
    - Updated `Initialization` block to use `interface: ide0`, `type: nocloud`, and added `ipConfigs` for static IP assignment at the Proxmox level.
    - Updated `ConfigPatches` to use `enp0s18` as the network interface name.
    - Removed `cdrom` block from `IgnoreChanges`.
- **Pulumi (`truenas.go`)**:
    - Reverted changes to TrueNAS VM and added `pulumi.Protect(true)` to prevent its destruction or replacement. The deprecation warning will persist to maintain stability.

## Verification
- CI Validation: Monitor the `Pulumi Preview` run for this PR. TrueNAS should now show as `unchanged` (plus protection) and any replacement would fail.
- Logs: Check for the absence of `verification warning` for Talos VMs, but expect it to remain for TrueNAS.

## Pull Request
[Pending]
