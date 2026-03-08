# TrueNAS VM Creation

## Date
March 8, 2026

## What was changed?
- Initialized the Pulumi provider for Proxmox VE (`github.com/muhlba91/pulumi-proxmoxve/sdk/v6`).
- Created the TrueNAS VM configuration in Pulumi (`pulumi/truenas.go`).
- Added specifications:
  - Node: `proxmox`
  - CPU: 4 cores, `host` type
  - RAM: 8GB
  - Boot Disk: 32GB VirtIO SCSI
  - Network: Bridge `vmbr0`
  - PCIe Passthrough: Dual Broadcom/LSI SAS3008 HBAs (`0000:c4:00.0` and `0000:c6:00.0`).

## Why was it changed?
With hardware passthrough enabled on the host, the next step is to provision the TrueNAS SCALE VM so that it has direct access to the HDDs via the HBA controllers. This allows TrueNAS to manage the storage pools properly, bypassing Proxmox ZFS.

## Related PR
Pending PR creation.
