# 2026-03-18: Fix Talos Static IP Configuration (v3)

## Overview

Fixed the root cause of Talos VMs not receiving their assigned static IPs and added DNS nameserver configuration.

## Rationale

The VMs boot from the Talos **metal** ISO (`talos-metal-amd64.iso`), which enters maintenance mode and does **not** read cloud-init data. The `Initialization` block (with `nocloud` type, `UserDataFileId`, and `IpConfigs`) was dead code that Talos never consumed. This was why static IPs were never applied despite being configured.

Additionally, the Talos machine config patches were missing DNS `nameservers`, which would prevent DNS resolution even after static IPs are applied.

## Changes

- **Pulumi (`talos.go`)**:
  - Removed the `Initialization` block from all VMs (CP + workers) — dead code with the metal ISO.
  - Removed the snippet upload resources (`storage.NewFile`) since they were only used by the `Initialization` block.
  - Removed the unused `storage` import.
  - Added DNS nameservers (`1.1.1.1`, `8.8.8.8`) to the `machine.network` section of all `ConfigPatches`.
  - Added Pulumi exports for machine configurations (`talos-cp-config`, `talos-worker-config-N`) so they can be retrieved with `pulumi stack output` and applied via `talosctl apply-config`.

## Verification

- `go build ./...` passes successfully.
- CI Validation: Monitor the `Pulumi Preview` run for this PR.
- After merge + `pulumi up`, VMs should boot into maintenance mode. Apply configs using:
  ```bash
  pulumi stack output talos-cp-config > cp.yaml
  talosctl apply-config --insecure --nodes <DHCP_IP> --file cp.yaml
  ```

## Pull Request

[Pending]
