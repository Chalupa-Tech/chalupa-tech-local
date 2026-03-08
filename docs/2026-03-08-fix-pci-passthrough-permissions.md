# Change Log: Fix Proxmox PCI Passthrough Permissions

**Date:** 2026-03-08
**Rationale:** The Proxmox API user lacks permissions to assign raw (non-mapped) PCI devices to VMs. By using Resource Mappings, we allow the API user to manage the hardware passthrough without requiring `root@pam` privileges.

## Changes Made
- Updated `pulumi/truenas.go` to use PCI Resource Mappings instead of raw PCI IDs.
- Switched `Id: "0000:c4:00.0"` to `Mapping: "hba_part_1"`.
- Switched `Id: "0000:c6:00.0"` to `Mapping: "hba_part_2"`.

## Manual Prerequisites
The following mappings must be created manually in the Proxmox UI (**Datacenter -> Resource Mappings -> PCI**) before running Pulumi:

1.  **Name:** `hba_part_1` -> **Path:** `0000:c4:00.0`
2.  **Name:** `hba_part_2` -> **Path:** `0000:c6:00.0`

**PR Reference:** [Pending]
