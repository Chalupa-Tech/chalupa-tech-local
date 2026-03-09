# Update TrueNAS VM and add Pulumi linting

## Overview
Updates the TrueNAS VM configuration for startup order and display type, and adds a linting job to the Pulumi workflow.

## Changes
- Updated `pulumi/truenas.go` to set `Startup.Order` to 1 and `Vga.Type` to "vmware".
- Updated `README.md` to document the manually installed Tailscale LXC container.
- Updated `.github/workflows/pulumi.yml` to add a `lint` job using `golangci-lint-action`.

## Rationale
- Setting `Startup.Order` ensures that the TrueNAS VM starts first among other VMs.
- Setting `Vga.Type` to "vmware" provides better compatibility for some guest operating systems.
- Documenting the Tailscale LXC container in the README provides better visibility for manually managed infrastructure.
- Adding linting to the CI/CD pipeline helps maintain code quality in the Pulumi Go project.

## PR Link
https://github.com/Chalupa-Tech/chalupa-tech-local/pull/9
