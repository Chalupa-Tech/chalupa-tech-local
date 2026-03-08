# Change Log: Fix Lint and Pulumi Issues in PR #2

## Summary
Resolved failures in Pull Request #2 related to Ansible linting and Pulumi workflow configuration.

## Changes
- **Ansible Roles**:
    - Renamed the role directory `ansible/roles/proxmox-prep` to `ansible/roles/proxmox_prep` to follow Ansible's naming conventions (underscores only).
    - Updated `ansible/site.yml` to use the new role name and changed `become: yes` to `become: true`.
    - Updated `ansible/roles/proxmox_prep/tasks/main.yml` to use the fully qualified collection name (FQCN) `ansible.builtin.apt` and changed `update_cache: yes` to `update_cache: true`.
- **Pulumi Configuration**:
    - Added the missing `stack-name: chalupa-infra/proxmox` to the Pulumi Preview and Pulumi Up jobs in `.github/workflows/pulumi.yml`.
    - Renamed the Pulumi stack configuration file from `pulumi/Pulumi.chalupa-local.yaml` to `pulumi/Pulumi.proxmox.yaml` to match the stack name provided.

## Rationale
- **Lint Compliance**: Following Ansible lint rules ensures better code quality and consistency. Renaming roles to use underscores and using FQCN for modules are standard practices.
- **Workflow Integrity**: The Pulumi GitHub Action requires a stack name to correctly identify which stack to operate on in the CI environment. Renaming the config file ensures the configuration is correctly picked up by the selected stack.
