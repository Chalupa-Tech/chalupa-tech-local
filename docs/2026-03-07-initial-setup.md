# Change Log: Initial Setup and Migration to Go

## Summary
This log covers the initial repository setup, CI/CD configuration, and the subsequent migration of the Pulumi project from TypeScript to Go.

## Changes
- **Repository Initialization**: Created `GEMINI.md`, `README.md`, and initial directory structures for Ansible and Pulumi.
- **CI/CD Integration**: Added GitHub Action workflows for Pulumi (`pulumi.yml`) and Ansible (`ansible.yml`).
- **Ansible Scaffolding**: Created inventory and a placeholder role for Proxmox host preparation.
- **Pulumi Migration**: Replaced the TypeScript Pulumi project with a Go-based project (`proxmox`) and initialized the `chalupa-local` stack.
- **Rules & Safety**: Added strict interaction rules for AI agents in `GEMINI.md`, including mandates for PR-only workflows, `gh` CLI usage, and modularity.

## Rationale
- **Infrastructure as Code**: To manage the local Proxmox homelab using professional-grade tools (Pulumi and Ansible).
- **Automation**: To ensure all changes are validated via CI previews and checks before being applied.
- **Language Preference**: Migrated to Go for Pulumi to align with user preference for the infrastructure codebase.
- **Traceability**: Established a `docs/` directory for explicit change tracking as part of repository standards.

## Aligned Pull Request
- [PR #1: feat: initial setup for Proxmox infrastructure and configuration](https://github.com/tayvenb13/chalupa-tech-local/pull/1)
