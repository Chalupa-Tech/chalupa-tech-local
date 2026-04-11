# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure-as-code for a local Proxmox hypervisor (AMD Strix Halo Framework desktop). Uses **Pulumi (Go)** for VM provisioning, **Ansible** for host/LXC configuration, deployed via **GitHub Actions** through PRs only.

## Architecture

**3-stage CI/CD pipeline** (`.github/workflows/deploy.yml`, triggered on merge to `main`):
1. **Stage 1** — Ansible prepares the Proxmox host (IOMMU, kernel 7, LXC template)
2. **Stage 2** — Pulumi provisions TrueNAS VM, exports Plex IP as artifact for Stage 3
3. **Stage 3** — Ansible creates Plex LXC on host (privileged, GPU, nesting), then configures software inside it (Plex, VA-API, NFS, firewall)

**Why Ansible manages the LXC (not Pulumi):** Proxmox restricts LXC device passthrough, feature flags, and privileged mode to `root@pam` identity only — API tokens cannot set these. Ansible runs as root on the host via SSH, so it has no such restrictions.

**PR workflows** run linting + dry-run previews:
- `ansible.yml`: `ansible-lint` then `--check --diff` against live host
- `pulumi.yml`: `golangci-lint` then `pulumi preview`

CI runners connect to the local network via **Tailscale** (OAuth, tag:github-runner).

**Pulumi program** (`pulumi/`): Go 1.25.6, stack `tayvenb13/chalupa-infra/proxmox`, provider `pulumi-proxmoxve` v7.13.0
- `main.go` — Provider setup (env vars: `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN`, `PROXMOX_VE_SSH_USERNAME`)
- `truenas.go` — TrueNAS Scale VM: 4 cores, 32GB RAM, HBA passthrough (2 mappings), boot order 1

**Ansible** (`ansible/`): Two inventories, two playbooks:
- `inventory.yml` + `site.yml` → `proxmox_prep` role (host config) against `pve1`
- `inventory-vms.yml` + `playbooks/vm-configure.yml` → `plex_lxc` role (container creation on `pve1`) then `plex_server` role (software config inside LXC)
- Shared vars in `group_vars/all.yml` (e.g., `truenas_vm_ip`)

**Plex LXC** (VMID 200): Ubuntu 24.04, privileged, 8 cores, 8GB RAM, 16GB disk, GPU `/dev/dri/renderD128` passthrough, static IP `192.168.1.224`, boot order 3

## Network

| Device | IP |
|---|---|
| Unifi Gateway | 192.168.1.1 |
| Proxmox host (pve1) | 192.168.1.223 |
| Plex LXC | 192.168.1.224 |
| TrueNAS VM | 192.168.1.40 |

## Commands

### Pulumi (from `pulumi/`)
```bash
cd pulumi && go build ./...          # Compile check
cd pulumi && golangci-lint run       # Lint
pulumi preview                       # Dry-run (requires env vars + Tailscale)
```

### SSH to Proxmox host
```bash
ssh -i ~/.ssh/pulumi_proxmox_runner root@192.168.1.223   # Verify host state
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
