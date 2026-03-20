# 2026-03-19: Fix Talos Static IP Configuration (v4)

## Overview

Updated the Talos VMs to boot from the new `nocloud-amd64.iso` image and enabled the QEMU guest agent.

## Rationale

The standard `talos-metal-amd64.iso` does not natively consume standard cloud-init or nocloud user-data via CD-ROM configuration out of the box without special configuration. By switching to the `nocloud-amd64.iso` downloaded by the user, the static IP assignments configured via cloud-init/nocloud data can be correctly processed upon initialization. Additionally, enabling the `qemu-guest-agent` allows Proxmox to accurately detect the network configuration and report the static IPs in the virtualization host dashboard.

## Changes

- **Pulumi (`talos.go`)**:
  - Changed `Cdrom.FileId` from `"local:iso/talos-metal-amd64.iso"` to `"local:iso/nocloud-amd64.iso"` for the Control Plane and Worker VMs.
  - Added `Agent: &vm.VirtualMachineAgentArgs{ Enabled: pulumi.Bool(true) }` to enable the QEMU guest agent for all Talos VMs.

## Pull Request

[PR #23](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/23)