# chalupa-tech-local

This repository manages the infrastructure and configuration for a local Proxmox server running on an AMD Strix Halo desktop from Framework. The setup relies on a combination of **Ansible** for host OS configuration and **Pulumi** (Go) for infrastructure provisioning.

## Hardware & Network Architecture

**Network Details:**

- **Router/Gateway:** Unifi Cloud Fiber Gateway (IP: `192.168.1.1`)
- **Proxmox IP:** `192.168.1.223:8006` (Static via Host OS & Unifi DHCP Reservation)

**Hypervisor Host:**

- **Hardware:** AMD Strix Halo Desktop (Framework)

### Virtual Machines (VMs)

1. **TrueNAS Scale (Storage NAS)** — VMID 100
   - **Resources:** 4 Cores, 32GB RAM
   - **Hardware Details:** PCIe Passthrough for HBA (ensures TrueNAS has direct, exclusive access to HDDs; bypasses Proxmox ZFS).
   - **File Shares:** Personal, Plex, Shared
   - **Managed by:** Pulumi (`pulumi/`)

2. **Talos Linux Kubernetes Cluster (3x VMs)** — VMIDs 300-302
   - **Resources:** 4 Cores, 20GB RAM _each_
   - **IPs:** 192.168.1.225 (CP), .226 (Worker 1), .227 (Worker 2)
   - **Workloads:** ArgoCD, Personal Website, \*arr stack, NzbGet
   - **Note:** Talos is an immutable OS built for K8s, bootstrapped via API. Fully destroyable and recreatable.
   - **Managed by:** Pulumi (`pulumi-talos/`)

3. **Ubuntu LXC (Plex Media Server)** — VMID 200
   - **Resources:** 8 Cores, 8GB RAM
   - **Hardware Details:** GPU Passthrough for hardware transcoding.
   - **Storage:** Mounts the "Plex" share from the TrueNAS VM.
   - **Managed by:** Ansible (`ansible/`)

4. **Tailscale LXC (Manual Setup)**
   - **Purpose:** Provides secure remote access to the local network.
   - **Note:** This container and Tailscale were both installed manually and are not currently managed by Pulumi.

## Repository Structure

- `ansible/roles/proxmox_prep`: Role for configuring the Proxmox host (IOMMU, GPU/HBA passthrough, LXC template, Talos ISO).
- `ansible/roles/plex_lxc`: Role for creating the Plex LXC container on the Proxmox host.
- `ansible/roles/plex_server`: Role for configuring Plex Media Server & NFS mounts inside the LXC.
- `pulumi/`: Pulumi (Go) project for TrueNAS VM provisioning.
- `pulumi-talos/`: Pulumi (Go) project for Talos K8s cluster (VMs, bootstrap, kubeconfig).
- `.github/workflows/`: GitHub Actions pipelines for CI/CD.

## Automation & CI/CD

Deployment and provisioning are handled entirely through Pull Requests and GitHub Actions:

- **Pulumi**: Runs `pulumi preview` on PRs (leaving a comment with the diff) and `pulumi up` on merge to `main`.
- **Ansible**: Runs linting and `ansible-playbook --check --diff` on PRs (posting results as a comment) and applies configuration on merge to `main`.

## Operational notes

### Adding a new VM: DHCP reservation is required

The Unifi gateway only issues a LAN IP to a MAC address that has a DHCP reservation. When `pulumi up` creates a new VM, Proxmox assigns it a freshly generated MAC, so DHCP fails and Talos boots without a LAN IP. The Pulumi run then errors with `no valid IP found for <node> via qemu-guest-agent` because `Ipv4Addresses` from the guest agent contains only loopback.

**When this fires:** the first `pulumi up` after a new node is added to `pulumi-talos/main.go` (or after a `pulumi destroy` + recreate). Existing nodes are unaffected — their MACs are stable in Pulumi state.

**Recovery (no destroy needed):**

1. Look up the new VM's MAC in the Proxmox UI (Hardware → Network Device) or via `ssh root@192.168.1.223 "qm config <VMID> | grep ^net0"`.
2. Add a DHCP reservation in the Unifi UI for that MAC.
3. Soft-reset the VM so Talos retries DHCP: `ssh root@192.168.1.223 "qm reset <VMID>"`.
4. Re-run the failed deploy workflow: `gh run rerun <RUN_ID> --failed`.

After the reservation grants an IP, Pulumi re-reads `Ipv4Addresses`, applies the Talos config (which sets the *final* static IP from the patch), and the node joins the cluster.
