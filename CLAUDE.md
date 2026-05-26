# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure-as-code for a local Proxmox hypervisor (AMD Strix Halo Framework desktop). Uses **Pulumi (Go)** for VM provisioning, **Ansible** for host/LXC configuration, deployed via **GitHub Actions** through PRs only.

## Architecture

**CI/CD pipeline** (`.github/workflows/deploy.yml`, triggered on merge to `main`):
1. **Stage 1** — Ansible prepares the Proxmox host (IOMMU, kernel 7, LXC template, Talos ISO)
2. **Stage 2a** — Pulumi provisions TrueNAS VM, exports Plex IP as artifact for Stage 3
3. **Stage 2b** — Pulumi provisions Talos K8s cluster (3 VMs, bootstrap, kubeconfig) *(parallel with 2a)*
4. **Stage 3** — Ansible creates Plex LXC on host (privileged, GPU, nesting), then configures software inside it (Plex, VA-API, NFS, firewall)
5. **Stage 4** — Helm bootstraps ArgoCD on the Talos cluster

**Why Ansible manages the LXC (not Pulumi):** Proxmox restricts LXC device passthrough, feature flags, and privileged mode to `root@pam` identity only — API tokens cannot set these. Ansible runs as root on the host via SSH, so it has no such restrictions.

**PR workflows** run linting + dry-run previews:
- `ansible.yml`: `ansible-lint` then `--check --diff` against live host
- `pulumi.yml`: `golangci-lint` then `pulumi preview` for both `pulumi/` and `pulumi-talos/` stacks

CI runners connect to the local network via **Tailscale** (OAuth, tag:github-runner).

**Pulumi — Infra** (`pulumi/`): Go 1.25.6, stack `tayvenb13/chalupa-infra/proxmox`, provider `pulumi-proxmoxve` v7.13.0
- `main.go` — Provider setup (env vars: `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN`, `PROXMOX_VE_SSH_USERNAME`)
- `truenas.go` — TrueNAS Scale VM: 4 cores, 32GB RAM, HBA passthrough (2 mappings), boot order 1

**Pulumi — Talos** (`pulumi-talos/`): Go 1.25.6, stack `tayvenb13/chalupa-talos/proxmox`, providers `pulumi-proxmoxve` v7.13.0 + `pulumi-talos` v0.7.1
- `main.go` — 5 Talos VMs (VMIDs 300, 304, 305 + 301, 302), cluster secrets, machine config generation/apply, bootstrap, kubeconfig + talosconfig export
- Separate stack from infra so `pulumi destroy` cleanly removes only Talos resources without affecting TrueNAS

**Ansible** (`ansible/`): Two inventories, two playbooks:
- `inventory.yml` + `site.yml` → `proxmox_prep` role (host config, Talos ISO download) against `pve1`
- `inventory-vms.yml` + `playbooks/vm-configure.yml` → `plex_lxc` role (container creation on `pve1`) then `plex_server` role (software config inside LXC)
- Shared vars in `group_vars/all.yml` (e.g., `truenas_vm_ip`)

**Plex LXC** (VMID 200): Ubuntu 24.04, privileged, 8 cores, 8GB RAM, 16GB disk, GPU `/dev/dri/renderD128` passthrough, static IP `192.168.1.224`, boot order 3

**Talos K8s Cluster** (VMIDs 300, 304, 305 + 301, 302, 303): Talos Linux v1.12.6, 6 nodes (3 CP + 3 workers — HA control plane). All CPs (.225, .228, .229): 2 cores / 4 GB / 50 GB disk each. Workers (.226, .227, .232): 4 cores / 20 GB / 100 GB disk each. Boot order 4 (CP) / 5 (worker). Cluster endpoint: https://192.168.1.231:6443 (Talos shared VIP). Fully destroyable and recreatable via pipeline.

## Network

| Device | IP |
|---|---|
| Unifi Gateway | 192.168.1.1 |
| Proxmox host (pve1) | 192.168.1.223 |
| Plex LXC | 192.168.1.224 |
| Talos CP (talos-cp) | 192.168.1.225 |
| Talos Worker 1 | 192.168.1.226 |
| Talos Worker 2 | 192.168.1.227 |
| Talos Worker 3 | 192.168.1.232 |
| Talos CP-2 (talos-cp-2) | 192.168.1.228 |
| Talos CP-3 (talos-cp-3) | 192.168.1.229 |
| Talos cluster VIP | 192.168.1.231 |
| TrueNAS VM | 192.168.1.40 |

## Commands

### Pulumi — Infra (from `pulumi/`)
```bash
cd pulumi && go build ./...          # Compile check
cd pulumi && golangci-lint run       # Lint
pulumi preview                       # Dry-run (requires env vars + Tailscale)
```

### Pulumi — Talos (from `pulumi-talos/`)
```bash
cd pulumi-talos && go build ./...    # Compile check
cd pulumi-talos && golangci-lint run # Lint
pulumi preview                       # Dry-run (requires env vars + Tailscale)
```

### Kubeconfig (from `pulumi-talos/`)
```bash
pulumi stack output kubeconfig --show-secrets > ~/.kube/chalupa-cluster.yaml
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
kubectl get nodes
```

### SSH to Proxmox host
```bash
ssh -i ~/.ssh/pulumi_proxmox_runner root@192.168.1.223   # Verify host state
```

### Home Assistant (HAOS VM 250, IP 192.168.1.234)

**SSH (passwordless sudo as `tayvenbigelow`):**
```bash
ssh tayvenbigelow@192.168.1.234 -i ~/.ssh/pulumi_proxmox_runner
```
- Root login is rejected; `tayvenbigelow` has `(ALL) NOPASSWD: ALL`.
- The SSH add-on container doesn't expose SFTP, so `scp` fails. Transfer files
  via pipe+tee then sudo-mv:
  ```bash
  cat local.py | ssh tayvenbigelow@192.168.1.234 "cat > /tmp/x.py"
  ssh tayvenbigelow@192.168.1.234 "sudo mv /tmp/x.py /config/pyscript/x.py"
  ```
- Pyscript auto-reloads on file mtime change in `/config/pyscript/` — no
  manual reload needed for `.py` updates.
- HAOS supervisor's `ha` CLI is **not usable** over SSH (SUPERVISOR_TOKEN
  isn't in the SSH session env, even with sudo). Use the REST API instead.

**REST API (Long-Lived Access Token):**
```bash
# Token is in $HOMEASSISTANT_TOKEN if you sourced ~/.zshrc, but
# non-interactive shells (incl. most agent tool calls) won't see it.
# Move the export to ~/.zshenv for non-interactive availability, OR fall back to:
TOK=$(cat ~/.config/ha/llat)
HA=http://192.168.1.234:8123

# Read a state
curl -s -H "Authorization: Bearer $TOK" "$HA/api/states/sensor.climate_balance_mode"

# Tail the live error log (only way to see HA logs — /config/home-assistant.log
# is rotated and the active log lives in the supervisor container)
curl -s -H "Authorization: Bearer $TOK" "$HA/api/error_log" | tail -50

# Call a service (e.g., reload Pyscript)
curl -s -X POST -H "Authorization: Bearer $TOK" -d '{}' "$HA/api/services/pyscript/reload"

# Set an input_number
curl -s -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"entity_id":"input_number.climate_balance_target_temp","value":72}' \
  "$HA/api/services/input_number/set_value"
```

**Notify (Discord):** the configured service is `notify.homeassistant_tejon_frame`,
not `notify.discord`. Pass `target=[<channel_id>]` for the climate-balance
channel (ID 1508674689256652850).

**Recorder DB (SQLite, read-only via SSH):**
```bash
ssh tayvenbigelow@192.168.1.234 "sudo sqlite3 -readonly /config/home-assistant_v2.db \
  \"SELECT m.entity_id, datetime(s.last_updated_ts,'unixepoch','localtime'), s.state \
   FROM states s JOIN states_meta m ON s.metadata_id=m.metadata_id \
   WHERE m.entity_id='sensor.climate_balance_mode' \
   ORDER BY s.last_updated_ts DESC LIMIT 10;\""
```
Modern HA schema separates entity IDs into `states_meta` and state values into
`states` (keyed on `metadata_id`). `last_updated_ts` is epoch seconds.

**Pyscript layout** (HACS add-on at `/config/custom_components/pyscript/`):
- `/config/pyscript/*.py` — **trigger scripts** (with `@state_trigger` / `@time_trigger`)
- `/config/pyscript/modules/*.py` — **importable libraries** (the only path
  trigger scripts can import from; not on `sys.path` for normal trigger files)
- `/config/packages/*.yaml` — packaged YAML (input_boolean, input_number,
  input_datetime helpers, etc.); requires `homeassistant: packages: !include_dir_named packages` in `configuration.yaml`

**Pyscript gotchas** (verified in production; in memory under `feedback_pyscript_*.md`):
- No lambda closures over enclosing-function args (use named helpers with positional args)
- No `@property` descriptor protocol (use module-level functions taking the instance)
- No generator expressions in `all(... for ... in ...)` (use explicit `and` chains)
- Service-call style required for dynamic service names: `service.call("notify", "<svc>", ...)`

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
