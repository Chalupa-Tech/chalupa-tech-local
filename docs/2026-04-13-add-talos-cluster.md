# Add Talos Kubernetes Cluster

## Summary

Added a 3-node Talos Linux Kubernetes cluster to the Proxmox host, managed declaratively via a separate Pulumi project (`pulumi-talos/`). The cluster is fully destroyable and recreatable by re-running the deploy pipeline.

## Rationale

A Kubernetes cluster is needed to run containerized workloads (ArgoCD, personal website, *arr stack, NzbGet). Talos Linux was chosen because:
- Immutable OS purpose-built for Kubernetes — no SSH, no package manager, minimal attack surface
- Declarative API-driven configuration eliminates drift
- Reproducible: same secrets + patches always produce the same cluster
- The Pulumi Talos provider (`pulumiverse/pulumi-talos`) handles the full lifecycle declaratively

A separate Pulumi stack (`chalupa-talos`) was created instead of adding to the existing `chalupa-infra` stack because:
- TrueNAS VM uses `pulumi.Protect(true)`, making `pulumi destroy` fail on the infra stack
- The Talos cluster must be fully destroyable/recreatable independently
- Clean separation of long-lived (TrueNAS) vs ephemeral (Talos) infrastructure

## Changes

### Ansible (`ansible/roles/proxmox_prep/`)
- Added Talos ISO download tasks to `proxmox_prep` role
- Downloads nocloud ISO with `siderolabs/qemu-guest-agent` extension from `factory.talos.dev`
- ISO stored at `/var/lib/vz/template/iso/talos-nocloud-amd64.iso` on Proxmox host

### Pulumi (`pulumi-talos/`)
- New Pulumi project with `pulumi-proxmoxve` v7.13.0 + `pulumi-talos` v0.7.1
- Creates 3 VMs: `talos-cp` (VMID 300), `talos-worker-1` (301), `talos-worker-2` (302)
- Each: 4 cores, 20GB RAM, 50GB disk, OVMF/q35, CPU type `host`, qemu-guest-agent
- Generates Talos machine secrets (stored in Pulumi state)
- Generates per-node machine configs with static IP patches
- Applies configs via DHCP IP from guest agent, nodes reboot to static IPs
- Bootstraps etcd on control plane node
- Exports `kubeconfig` and `talosconfig` as secret stack outputs

### CI/CD (`.github/workflows/`)
- `deploy.yml`: Added Stage 2b (Talos Pulumi, parallel with 2a) and Stage 4 (ArgoCD Helm bootstrap)
- `pulumi.yml`: Added Talos lint + preview jobs for PR checks

### Documentation
- Updated `CLAUDE.md` with Talos architecture, network table, commands
- Updated `README.md` with correct VM specs and repo structure

## Network

| Node | VMID | IP | Boot Order |
|------|------|----|------------|
| talos-cp | 300 | 192.168.1.225 | 4 |
| talos-worker-1 | 301 | 192.168.1.226 | 5 |
| talos-worker-2 | 302 | 192.168.1.227 | 5 |

## Action Required

1. Initialize the Pulumi stack: `cd pulumi-talos && pulumi stack init tayvenb13/chalupa-talos/proxmox`
2. After pipeline runs, retrieve kubeconfig: `pulumi stack output kubeconfig --show-secrets > ~/.kube/chalupa-cluster.yaml`
