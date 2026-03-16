# 2026-03-16: Fix Missing Proxmox Snippets Directory

## Overview
Fixed a failure in the `Pulumi Up` GitHub Actions workflow (Run ID: 23123599515) where Talos configuration snippets could not be uploaded.

## Rationale
The `proxmoxve:Storage:File` resource was failing because the `/var/lib/vz/snippets` directory did not exist on the Proxmox host. Proxmox requires this directory for storage identified as `local` when the content type is `snippets`. The Pulumi provider does not automatically create this directory on the host's filesystem.

## Changes
- Updated `ansible/roles/proxmox_prep/tasks/main.yml` to include a task that ensures `/var/lib/vz/snippets` exists with the correct permissions (`0755`) and ownership (`root:root`).

## Verification
1. Merge this PR.
2. The `Ansible` workflow will run first and create the directory.
3. The `Pulumi Up` workflow will then succeed in uploading the snippets.

## Pull Request
[PR #13](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/13)
