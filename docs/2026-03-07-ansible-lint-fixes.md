# Change Log: Ansible Linting and Refactoring

## Summary
Fixed several fatal Ansible linting violations to align with professional standards and repository rules.

## Changes
- **Role Renaming**: Renamed the role `proxmox-prep` to `proxmox_prep` to follow the required `^[a-z][a-z0-9_]*$` naming convention.
- **FQCN Usage**: Updated the `apt` module in the `proxmox_prep` role tasks to use its Fully Qualified Collection Name (FQCN): `ansible.builtin.apt`.
- **YAML Formatting**: Replaced truthy values (`yes`) with strict boolean values (`true`) in `ansible/site.yml` and role task files to satisfy `ansible-lint` requirements.
- **Documentation Refactoring**: Updated `docs/2026-03-07-initial-setup.md` references (implicitly updated by refactor).

## Rationale
- **Code Quality**: Adhering to `ansible-lint` ensures maintainable and idiomatic Ansible code.
- **Best Practices**: Using FQCN and standard YAML booleans is recommended for modern Ansible development.
- **Consistency**: Maintaining a consistent naming convention for roles across the project.
