# 2026-03-15: Fix Pulumi Workflow SSH Authentication Issue

## Overview
Fixed a failure in the `Pulumi Up` GitHub Actions workflow (Run ID: 23117232419).

## Rationale
The `muhlba91/proxmoxve` Pulumi provider requires an SSH connection to upload specific file types (like "snippets" used for our Talos Machine Configurations) to Proxmox storage (`proxmoxve:Storage:File`). The workflow was failing because the GitHub Actions runner lacked the necessary SSH credentials.

To maintain consistency and security, we have aligned Pulumi's SSH authentication with the existing Ansible workflow, utilizing an SSH agent.

## Changes
- **Workflow Update**: Updated `.github/workflows/pulumi.yml` to include `webfactory/ssh-agent` setup using `${{ secrets.PROXMOX_SSH_KEY }}` and added the Proxmox host to `known_hosts`.
- **Go Code Update**:
    - Modified `pulumi/main.go` to explicitly create a Proxmox provider with SSH agent support enabled (`Agent: true`).
    - Added a default value for SSH username (`root`), matching the Ansible inventory. This ensures that the Pulumi code doesn't fail if `PROXMOX_VE_SSH_USERNAME` is not set in the environment.
    - Updated `pulumi/truenas.go` and `pulumi/talos.go` to accept and use this explicit provider for all Proxmox resource creations.
- **Environment Variables**: The workflow now passes `PROXMOX_VE_SSH_USERNAME` to the Pulumi environment.

## Action Required
Ensure the following repository secrets are configured in GitHub:
- `PROXMOX_SSH_KEY`: The SSH private key used to access the Proxmox node (already used by Ansible).
- `PROXMOX_VE_SSH_USERNAME`: (Optional) The Proxmox node SSH username. Defaults to `root` if not provided.

## Pull Request
[PR #12](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/12)
