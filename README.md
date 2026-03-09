# chalupa-tech-local

This repository manages the infrastructure and configuration for a local Proxmox server running on an AMD Strix Halo desktop from Framework. The setup relies on a combination of **Ansible** for host OS configuration and **Pulumi** (TypeScript) for infrastructure provisioning.

## Hardware & Network Architecture

**Network Details:**
* **Router/Gateway:** Unifi Cloud Fiber Gateway (IP: `192.168.1.1`)
* **Proxmox IP:** `192.168.1.223:8006` (Static via Host OS & Unifi DHCP Reservation)

**Hypervisor Host:**
* **Hardware:** AMD Strix Halo Desktop (Framework)

### Virtual Machines (VMs)

1. **TrueNAS Scale (Storage NAS)**
   * **Resources:** 4 Cores, 12GB RAM
   * **Hardware Details:** PCIe Passthrough for HBA (ensures TrueNAS has direct, exclusive access to HDDs; bypasses Proxmox ZFS).
   * **File Shares:** Personal, Plex, Shared

2. **Talos Linux Kubernetes Cluster (3x VMs)**
   * **Resources:** 4 Cores, 16GB RAM *each*
   * **Workloads:** Personal Website, *arr stack, NzbGet
   * **Note:** Talos is an immutable OS built for K8s, bootstrapped via API.

3. **Ubuntu Server (Plex Media Server)**
   * **Resources:** 8 Cores, 32GB RAM
   * **Hardware Details:** GPU Passthrough for hardware transcoding.
   * **Storage:** Mounts the "Plex" share from the TrueNAS VM.

4. **Tailscale LXC (Manual Setup)**
   * **Purpose:** Provides secure remote access to the local network.
   * **Note:** This container and Tailscale were both installed manually and are not currently managed by Pulumi.

## Repository Structure

* `ansible/`: Contains playbooks, inventory, and roles for configuring the Proxmox host (e.g., enabling IOMMU, configuring GPU/HBA passthrough).
* `pulumi/`: Contains the TypeScript Pulumi project for defining the VMs (Proxmox provider) and bootstrapping the Talos cluster.
* `.github/workflows/`: GitHub Actions pipelines for CI/CD.

## Automation & CI/CD

Deployment and provisioning are handled entirely through Pull Requests and GitHub Actions:
- **Pulumi**: Runs `pulumi preview` on PRs (leaving a comment with the diff) and `pulumi up` on merge to `main`.
- **Ansible**: Runs linting and `ansible-playbook --check --diff` on PRs (posting results as a comment) and applies configuration on merge to `main`.
