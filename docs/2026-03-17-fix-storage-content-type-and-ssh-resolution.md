# 2026-03-17: Fix Proxmox Storage Content Type and SSH Resolution

## Overview
Fixed a failure in the `Pulumi Up` workflow (Run ID: 23123938362) where Talos configuration snippets failed with "failed to read file".

## Rationale
The error `failed to read file` in the Proxmox Pulumi provider often occurs during the creation of `proxmoxve:Storage:File` resources when using `SourceRaw`. This can be caused by:
1.  **Missing Content Type**: The `local` storage on the Proxmox host might not have the `snippets` content type enabled in `/etc/pve/storage.cfg`.
2.  **SSH Resolution Issue**: The Pulumi provider uses SSH to upload files for `dir` type storage. If the runner cannot resolve the node name (e.g., `proxmox` or `pve1`) to its IP address, the SSH connection may fail or behave inconsistently.

## Changes
- **Ansible Role (`proxmox_prep`)**: Added a task to explicitly enable the `snippets` content type on the `local` storage using `pvesm set local --content snippets,iso,vztmpl,backup`.
- **Workflows**:
    - Updated `.github/workflows/pulumi.yml` to include host resolution in `/etc/hosts` for both `proxmox` and `pve1`, and added these to `known_hosts`.
    - Updated `.github/workflows/ansible.yml` with the same host resolution for consistency.

## Verification
- Pre-checks: `ansible-lint` and `go build` (manual) confirm no syntax errors.
- CI Validation: Monitor the next `Pulumi Up` run on `main`.

## Pull Request
[Pending]
