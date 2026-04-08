# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure-as-code for a local Proxmox hypervisor (AMD Strix Halo Framework desktop). Uses **Pulumi (Go)** for VM provisioning and **Ansible** for host/VM configuration, deployed via **GitHub Actions** through PRs only.

## Architecture

**3-stage CI/CD pipeline** (`.github/workflows/deploy.yml`, triggered on merge to `main`):
1. **Stage 1** — Ansible prepares the Proxmox host (IOMMU, VFIO, Fedora 43 cloud template VMID 9000)
2. **Stage 2** — Pulumi provisions VMs (TrueNAS, Plex), exports Plex IP as artifact for Stage 3
3. **Stage 3** — Ansible configures VM software (Plex install, NFS mounts, firewall)

**PR workflows** run linting + dry-run previews:
- `ansible.yml`: `ansible-lint` then `--check --diff` against live host
- `pulumi.yml`: `golangci-lint` then `pulumi preview` (includes state cleanup step for legacy resources)

CI runners connect to the local network via **Tailscale** (OAuth, tag:github-runner).

**Pulumi program** (`pulumi/`): Go 1.25.6, stack `tayvenb13/chalupa-infra/proxmox`, provider `pulumi-proxmoxve` v7.13.0
- `main.go` — Provider setup (env vars: `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN`, `PROXMOX_VE_SSH_USERNAME`)
- `truenas.go` — TrueNAS Scale VM: 4 cores, 32GB RAM, HBA passthrough (2 mappings), boot order 1
- `plex.go` — Plex VM: VMID 200, 8 cores, 32GB RAM, GPU passthrough (`strix_halo_gpu`), cloud-init (user `fedora`, static IP `192.168.1.224`), boot order 3

**Ansible** (`ansible/`): Two inventories, two playbooks:
- `inventory.yml` + `site.yml` → `proxmox_prep` role against host `pve1` (192.168.1.223)
- `inventory-vms.yml` + `playbooks/vm-configure.yml` → `plex_server` role against Plex VM
- Shared vars in `group_vars/all.yml` (e.g., `truenas_vm_ip`)

## Network

| Device | IP |
|---|---|
| Unifi Gateway | 192.168.1.1 |
| Proxmox host (pve1) | 192.168.1.223 |
| Plex VM | 192.168.1.224 |
| TrueNAS VM | 192.168.1.40 |

## Commands

### Pulumi (from `pulumi/`)
```bash
cd pulumi && go build ./...          # Compile check
cd pulumi && golangci-lint run       # Lint
pulumi preview                       # Dry-run (requires env vars + Tailscale)
```

### Ansible (from `ansible/`)
```bash
cd ansible && ansible-lint           # Lint
ansible-playbook -i inventory.yml site.yml --check --diff   # Dry-run host prep
```

## Critical Rules

- **All changes via PRs** — never push directly to `main`
- **No local `pulumi up` or `ansible-playbook` (without `--check`)** — CI is the source of truth for applying changes
- **No destructive operations** on TrueNAS or other data-bearing systems
- **TrueNAS VM is protected** — the TrueNAS VM (`truenas-scale`) uses `pulumi.Protect(true)` and MUST NEVER be deleted or have its protection removed. This VM manages data-bearing storage.
- **Document changes** in `docs/` with rationale and PR link
- Pulumi uses `pulumi.IgnoreChanges([]string{"started"})` on VMs to avoid restart drift
- The `pulumi.yml` PR workflow includes a state cleanup step that filters old resources via `jq` — be careful when modifying resource names as this affects state filtering logic
