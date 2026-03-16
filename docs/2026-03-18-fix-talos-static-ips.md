# 2026-03-18: Fix Talos Static IP Configuration

## Overview
Fixed an issue where Talos nodes were receiving DHCP IP addresses instead of the intended static IPs, causing the bootstrap process to fail (Run ID: 23129262471).

## Rationale
The `talos:machine:Bootstrap` resource was failing with `no route to host` because it was trying to connect to `192.168.1.41`, but the node had received a random DHCP IP (e.g., `192.168.1.238`). Talos nodes require explicit network configuration in their machine configuration YAML to apply static IPs.

## Changes
- **Pulumi (`talos.go`)**:
    - Added `ConfigPatches` to the Control Plane machine configuration to set a static IP (`192.168.1.41`), subnet mask (`/24`), and gateway (`192.168.1.1`).
    - Refactored the worker VM provisioning loop to generate unique machine configurations and snippets for each worker node.
    - Added `ConfigPatches` to each Worker node to set unique static IPs (`192.168.1.42`, `192.168.1.43`).

## Verification
- CI Validation: Monitor the next `Pulumi Up` run on `main`. The nodes should now apply the static IPs from the provided snippets upon boot.

## Pull Request
[Pending]
