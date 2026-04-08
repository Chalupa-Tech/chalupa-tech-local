# Plex Server VM — Implementation Plan (Final)

> **Status**: Awaiting approval to execute.
> All open questions resolved. Ready for implementation.

---

## Overview

Provisions and configures a new **Fedora 43** Plex Media Server VM on Proxmox using a three-stage CI/CD pipeline:

```
Stage 1: Ansible  → Proxmox Prep   (existing role + Fedora cloud template creation)
Stage 2: Pulumi   → VM Provision   (clone template, GPU passthrough, cloud-init config)
Stage 3: Ansible  → VM Config      (install Plex, mount NFS, create tbigelow user)
```

---

## Confirmed Parameters

| Parameter             | Value                                                                |
| --------------------- | -------------------------------------------------------------------- |
| OS Image              | Fedora Cloud Base 43 QCOW2 (cloud-init native)                       |
| Proxmox Template VMID | `9000` — created by Ansible, not managed by Pulumi                   |
| Plex VM ID            | `200`                                                                |
| Plex Hostname         | `plex`                                                               |
| Plex Static IP        | `192.168.1.224/24` (GW `192.168.1.1`)                                |
| DNS Servers           | `192.168.1.1` (primary), `1.1.1.1` (backup)                          |
| GPU PCIe Mapping      | `strix_halo_gpu` (Proxmox Resource Mapping)                          |
| GPU Passthrough       | Active — hardware transcoding enabled                                |
| CPU Cores             | `8`                                                                  |
| RAM                   | `32 GB`                                                              |
| Boot Disk             | `64 GB` on `local-lvm`                                               |
| Startup Order         | `3` (after TrueNAS=1)                                                |
| Ansible User          | `fedora` (default Fedora cloud user, has wheel/sudo)                 |
| Personal User         | `tbigelow` — created by Ansible plex_server role with SSH key + sudo |
| SSH Key Pair          | Same key as `PROXMOX_SSH_KEY` secret; public half in `public_keys/tbigelow.pub` |
| TrueNAS IP            | `192.168.1.40`                                                       |
| TrueNAS NFS Shares    | `/mnt/PlexMedia/Movies` and `/mnt/PlexMedia/TVShows`                 |
| Plex Mount Points     | `/mnt/plex/movies` and `/mnt/plex/tvshows`                           |

---

## User Review Required

> [!IMPORTANT]
> **Workflow consolidation**: The deploy jobs currently in `ansible.yml` and `pulumi.yml` will be **removed** and replaced by the unified `deploy.yml`. The lint/preview/check PR jobs stay untouched. This means merges to `main` will go through the new 3-stage pipeline instead of running Ansible and Pulumi independently.

> [!WARNING]
> **`go.mod` cleanup**: The `pulumiverse/pulumi-talos/sdk` dependency (line 8 of `go.mod`) is now unused after removing the Talos call. We should run `go mod tidy` to clean it out, otherwise `golangci-lint` will flag it.

---

## Proposed Changes

### Stage 1 — Ansible: Proxmox Prep (Template Creation)

Summary: Extend the existing `proxmox_prep` role to download the Fedora 43 Cloud Base QCOW2 and create a Proxmox VM template (VMID 9000) that Pulumi will clone from.

---

#### [MODIFY] [main.yml](file:///Users/tbigelow/Documents/code/chalupa-tech-local/ansible/roles/proxmox_prep/defaults/main.yml)

Add variables for Fedora Cloud Base image URL, template VMID, and storage target. Append these after the existing `proxmox_prep_cpu_vendor` line:

```yaml
---
proxmox_prep_cpu_vendor: amd

# Fedora Cloud template settings
fedora_cloud_image_url: "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.1.x86_64.qcow2"
fedora_cloud_image_checksum: "sha256:REPLACE_WITH_ACTUAL_CHECKSUM"
fedora_template_vmid: 9000
fedora_template_name: "fedora-43-cloud-template"
fedora_template_storage: "local-lvm"
fedora_cloud_image_dest: "/tmp/fedora-cloud-base.qcow2"
```

> [!IMPORTANT]
> **Before implementing:** Go to https://fedoraproject.org/cloud/download/ and get the SHA256 checksum for the exact QCOW2 file. Replace `REPLACE_WITH_ACTUAL_CHECKSUM` with the real value (format: `sha256:abc123...`). The filename portion (`43-1.1`) is the compose ID — verify it matches the current release.

---

#### [MODIFY] [main.yml](file:///Users/tbigelow/Documents/code/chalupa-tech-local/ansible/roles/proxmox_prep/tasks/main.yml)

Append the following idempotent block **after** the existing VFIO tasks (after line 59):

```yaml
# --- Fedora Cloud Template Creation (VMID 9000) ---
- name: Check if Fedora cloud template already exists
  ansible.builtin.command: qm status {{ fedora_template_vmid }}
  register: fedora_template_check
  failed_when: false
  changed_when: false

- name: Create Fedora cloud template
  when: fedora_template_check.rc != 0
  block:
    - name: Download Fedora Cloud Base QCOW2
      ansible.builtin.get_url:
        url: "{{ fedora_cloud_image_url }}"
        dest: "{{ fedora_cloud_image_dest }}"
        checksum: "{{ fedora_cloud_image_checksum }}"
        mode: '0644'

    - name: Create template VM shell
      ansible.builtin.command: >
        qm create {{ fedora_template_vmid }}
        --name {{ fedora_template_name }}
        --memory 2048
        --net0 virtio,bridge=vmbr0
        --scsihw virtio-scsi-pci
        --bios ovmf
        --machine q35
        --agent enabled=1
        --serial0 socket
      changed_when: true

    - name: Add EFI disk to template
      ansible.builtin.command: >
        qm set {{ fedora_template_vmid }}
        --efidisk0 {{ fedora_template_storage }}:0,pre-enrolled-keys=0
      changed_when: true

    - name: Import QCOW2 as boot disk
      ansible.builtin.command: >
        qm set {{ fedora_template_vmid }}
        --scsi0 {{ fedora_template_storage }}:0,import-from={{ fedora_cloud_image_dest }}
      changed_when: true

    - name: Add cloud-init CD-ROM drive
      ansible.builtin.command: >
        qm set {{ fedora_template_vmid }}
        --ide2 {{ fedora_template_storage }}:cloudinit
      changed_when: true

    - name: Set boot order to scsi0
      ansible.builtin.command: >
        qm set {{ fedora_template_vmid }}
        --boot order=scsi0
      changed_when: true

    - name: Convert to template
      ansible.builtin.command: qm template {{ fedora_template_vmid }}
      changed_when: true

    - name: Remove temporary QCOW2 file
      ansible.builtin.file:
        path: "{{ fedora_cloud_image_dest }}"
        state: absent
```

**Why specific commands were chosen:**
- `qm create` with `--scsihw virtio-scsi-pci` — required SCSI controller for cloud image boot disks
- `--bios ovmf --machine q35` — UEFI boot, required for GPU passthrough later
- `--agent enabled=1` — enables QEMU Guest Agent channel so Proxmox can query VM state
- `--serial0 socket` — cloud images expect a serial console; without it, no console output in Proxmox
- `qm set --scsi0 ... import-from=` — single-command import + attach (cleaner than `qm importdisk` + separate attach)
- `--ide2 ... cloudinit` — dedicated cloud-init drive, required for Pulumi's `Initialization` block to inject config
- `--boot order=scsi0` — without this, the VM may try to boot from the cloud-init IDE drive or PXE
- `--efidisk0 ... pre-enrolled-keys=0` — EFI variable store; `pre-enrolled-keys=0` means no Secure Boot (simpler)

---

#### [NEW] `ansible/group_vars/all.yml`

Create this file in the **existing** `ansible/group_vars/` directory:

```yaml
---
truenas_vm_ip: "192.168.1.40"
```

This makes `truenas_vm_ip` available to all playbooks/roles via Ansible's group_vars hierarchy.

---

### Stage 2 — Pulumi: Plex VM

Summary: New `plex.go` file clones the template, configures GPU passthrough, cloud-init networking, and exports the Plex IP. Follows the pattern of `truenas.go` but adds `Clone`, `Initialization`, `EfiDisk`, and `VmId` blocks which are new to this repo.

---

#### [NEW] `pulumi/plex.go`

```go
package main

import (
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v6/go/proxmoxve"
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v6/go/proxmoxve/vm"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func createPlexVM(ctx *pulumi.Context, pveProvider *proxmoxve.Provider) error {
	_, err := vm.NewVirtualMachine(ctx, "plex", &vm.VirtualMachineArgs{
		NodeName:    pulumi.String("proxmox"),
		VmId:        pulumi.Int(200),
		Name:        pulumi.String("plex"),
		Description: pulumi.String("Plex Media Server VM (Managed by Pulumi)"),
		Bios:        pulumi.String("ovmf"),
		Machine:     pulumi.String("q35"),

		// Clone from Fedora 43 cloud template (created by Ansible in Stage 1)
		Clone: &vm.VirtualMachineCloneArgs{
			NodeName: pulumi.String("proxmox"),
			VmId:     pulumi.Int(9000),
			Full:     pulumi.Bool(true),
		},

		Cpu: &vm.VirtualMachineCpuArgs{
			Cores: pulumi.Int(8),
			Type:  pulumi.String("host"),
		},
		Memory: &vm.VirtualMachineMemoryArgs{
			Dedicated: pulumi.Int(32768), // 32 GB
		},

		// EFI disk — required for OVMF BIOS; inherited from template but
		// explicitly declared so Pulumi manages it
		EfiDisk: &vm.VirtualMachineEfiDiskArgs{
			DatastoreId:     pulumi.String("local-lvm"),
			FileFormat:      pulumi.String("raw"),
			PreEnrolledKeys: pulumi.Bool(false),
		},

		// Boot disk — resize the cloned 2 GB template disk to 64 GB
		Disks: vm.VirtualMachineDiskArray{
			&vm.VirtualMachineDiskArgs{
				DatastoreId: pulumi.String("local-lvm"),
				Interface:   pulumi.String("scsi0"),
				Size:        pulumi.Int(64),
				FileFormat:  pulumi.String("raw"),
			},
		},

		NetworkDevices: vm.VirtualMachineNetworkDeviceArray{
			&vm.VirtualMachineNetworkDeviceArgs{
				Bridge: pulumi.String("vmbr0"),
			},
		},

		// GPU passthrough via Proxmox Resource Mapping
		Hostpcis: vm.VirtualMachineHostpciArray{
			&vm.VirtualMachineHostpciArgs{
				Device:  pulumi.String("hostpci0"),
				Mapping: pulumi.String("strix_halo_gpu"),
				Pcie:    pulumi.Bool(true),
				Rombar:  pulumi.Bool(true),
			},
		},

		// Cloud-init configuration — applied on first boot
		Initialization: &vm.VirtualMachineInitializationArgs{
			DatastoreId: pulumi.String("local-lvm"),
			UserAccount: &vm.VirtualMachineInitializationUserAccountArgs{
				Username: pulumi.String("fedora"),
				Keys: pulumi.StringArray{
					pulumi.String("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINvR9jYqq/EEuoMyJEloxILC6XfNAGHwoaMP4fMNk7ca"),
				},
			},
			IpConfigs: vm.VirtualMachineInitializationIpConfigArray{
				&vm.VirtualMachineInitializationIpConfigArgs{
					Ipv4: &vm.VirtualMachineInitializationIpConfigIpv4Args{
						Address: pulumi.String("192.168.1.224/24"),
						Gateway: pulumi.String("192.168.1.1"),
					},
				},
			},
			Dns: &vm.VirtualMachineInitializationDnsArgs{
				Servers: pulumi.StringArray{
					pulumi.String("192.168.1.1"),
					pulumi.String("1.1.1.1"),
				},
			},
		},

		// Display: none — required for GPU passthrough, prevents virtual VGA
		// from conflicting with the passed-through GPU
		Vga: &vm.VirtualMachineVgaArgs{
			Type: pulumi.String("none"),
		},

		Agent: &vm.VirtualMachineAgentArgs{
			Enabled: pulumi.Bool(true),
		},

		OperatingSystem: &vm.VirtualMachineOperatingSystemArgs{
			Type: pulumi.String("l26"),
		},

		Started: pulumi.Bool(true),
		OnBoot:  pulumi.Bool(true),
		Startup: &vm.VirtualMachineStartupArgs{
			Order: pulumi.Int(3),
		},

		SerialDevices: vm.VirtualMachineSerialDeviceArray{
			&vm.VirtualMachineSerialDeviceArgs{
				Device: pulumi.String("serial0"),
			},
		},
	}, pulumi.Provider(pveProvider), pulumi.IgnoreChanges([]string{"started"}))
	if err != nil {
		return err
	}

	ctx.Export("plex-ip", pulumi.String("192.168.1.224"))

	return nil
}
```

**Key differences from [truenas.go](file:///Users/tbigelow/Documents/code/chalupa-tech-local/pulumi/truenas.go) (for context):**

| Feature | `truenas.go` | `plex.go` |
|---------|-------------|-----------|
| `VmId` | Auto-assigned | Explicitly `200` |
| `Clone` | Not used (bare VM) | Clones template `9000` |
| `Initialization` | Not used | Cloud-init: static IP, SSH key, DNS |
| `EfiDisk` | Not present | Required for OVMF |
| `Vga.Type` | `"vmware"` | `"none"` (GPU passthrough) |
| `Agent` | Not set | Explicitly enabled |
| `SerialDevices` | Not set | `serial0` (cloud image console) |

> [!WARNING]
> **Edge case — disk resize on clone:** When cloning a template and specifying a `Disks` block with a `Size` larger than the template, the provider should resize automatically. If `pulumi preview` shows the disk being **replaced** rather than resized, remove the `Disks` block entirely and resize post-creation with an Ansible task: `qm resize 200 scsi0 64G`. Watch for this in the PR preview output.

> [!WARNING]
> **Edge case — `Dns` field API shape:** The `Dns.Servers` field in `VirtualMachineInitializationDnsArgs` may be named `Servers` or `Server` (singular string, space-separated) depending on the exact provider version (`v6.18.1`). If compilation fails on `Servers`, try:
> ```go
> Dns: &vm.VirtualMachineInitializationDnsArgs{
>     Server: pulumi.String("192.168.1.1 1.1.1.1"),
> },
> ```

---

#### [MODIFY] [main.go](file:///Users/tbigelow/Documents/code/chalupa-tech-local/pulumi/main.go)

Add the `createPlexVM` call after the TrueNAS VM (after line 38):

```diff
 		// Create TrueNAS VM
 		if err := createTrueNASVM(ctx, pveProvider); err != nil {
 			return err
 		}

+		// Create Plex Media Server VM
+		if err := createPlexVM(ctx, pveProvider); err != nil {
+			return err
+		}
+
 		return nil
```

---

#### [CLEANUP] `pulumi/go.mod`

Run `go mod tidy` to remove the unused `pulumiverse/pulumi-talos/sdk` dependency (line 8). This will also clean up any transitive deps that were only pulled in by Talos.

```bash
cd pulumi && go mod tidy
```

---

### Stage 3 — Ansible: Plex Server VM Configuration

Summary: New `plex_server` role installs Plex, mounts **two** TrueNAS NFS shares (movies + TV shows), creates the `tbigelow` user, and opens the firewall.

---

#### [NEW] `ansible/roles/plex_server/defaults/main.yml`

```yaml
---
plex_nfs_server: "{{ truenas_vm_ip }}"
plex_nfs_shares:
  - src: "/mnt/PlexMedia/Movies"
    dest: "/mnt/plex/movies"
  - src: "/mnt/PlexMedia/TVShows"
    dest: "/mnt/plex/tvshows"
plex_ssh_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINvR9jYqq/EEuoMyJEloxILC6XfNAGHwoaMP4fMNk7ca"
plex_user: "tbigelow"
plex_repo_url: "https://downloads.plex.tv/repo/rpm/x86_64/"
plex_repo_gpgkey: "https://downloads.plex.tv/plex-keys/PlexSign.v2.key"
```

---

#### [NEW] `ansible/roles/plex_server/tasks/main.yml`

```yaml
---
# ──────────────────────────────────────────────────────────
# 1. Wait for cloud-init to finish and SSH to become available
# ──────────────────────────────────────────────────────────
- name: Wait for VM to be reachable
  ansible.builtin.wait_for_connection:
    delay: 10
    timeout: 300

# ──────────────────────────────────────────────────────────
# 2. Gather system facts (needed for ansible_os_family, etc.)
# ──────────────────────────────────────────────────────────
- name: Gather facts
  ansible.builtin.setup:

# ──────────────────────────────────────────────────────────
# 3. Install and start QEMU Guest Agent
#    Lets Proxmox see VM IP, issue clean shutdowns, freeze FS for snapshots
# ──────────────────────────────────────────────────────────
- name: Install qemu-guest-agent
  ansible.builtin.dnf:
    name: qemu-guest-agent
    state: present

- name: Enable and start qemu-guest-agent
  ansible.builtin.systemd:
    name: qemu-guest-agent
    enabled: true
    state: started

# ──────────────────────────────────────────────────────────
# 4. Create personal user with sudo access
# ──────────────────────────────────────────────────────────
- name: Create user {{ plex_user }}
  ansible.builtin.user:
    name: "{{ plex_user }}"
    groups: wheel
    append: true
    shell: /bin/bash
    create_home: true

- name: Add SSH authorized key for {{ plex_user }}
  ansible.posix.authorized_key:
    user: "{{ plex_user }}"
    key: "{{ plex_ssh_key }}"
    state: present

# Separate sudoers drop-in file so we don't edit the main /etc/sudoers
- name: Grant passwordless sudo to wheel group
  ansible.builtin.lineinfile:
    path: /etc/sudoers.d/wheel-nopasswd
    line: "%wheel ALL=(ALL) NOPASSWD: ALL"
    create: true
    mode: "0440"
    validate: "visudo -cf %s"

# ──────────────────────────────────────────────────────────
# 5. Install NFS client utilities
# ──────────────────────────────────────────────────────────
- name: Install nfs-utils
  ansible.builtin.dnf:
    name: nfs-utils
    state: present

# ──────────────────────────────────────────────────────────
# 6. Create NFS mount points and mount shares
#    Uses x-systemd.automount so the VM won't hang at boot
#    if TrueNAS is temporarily unreachable.
# ──────────────────────────────────────────────────────────
- name: Create Plex media mount points
  ansible.builtin.file:
    path: "{{ item.dest }}"
    state: directory
    mode: "0755"
  loop: "{{ plex_nfs_shares }}"

- name: Mount TrueNAS NFS shares
  ansible.posix.mount:
    src: "{{ plex_nfs_server }}:{{ item.src }}"
    path: "{{ item.dest }}"
    fstype: nfs
    opts: "defaults,_netdev,nofail,x-systemd.automount,x-systemd.device-timeout=10s"
    state: mounted
  loop: "{{ plex_nfs_shares }}"

# ──────────────────────────────────────────────────────────
# 7. Add Plex Media Server RPM repository
# ──────────────────────────────────────────────────────────
- name: Add Plex RPM repository
  ansible.builtin.yum_repository:
    name: plex
    description: Plex Media Server
    baseurl: "{{ plex_repo_url }}"
    enabled: true
    gpgcheck: true
    gpgkey: "{{ plex_repo_gpgkey }}"

# ──────────────────────────────────────────────────────────
# 8. Install Plex Media Server
# ──────────────────────────────────────────────────────────
- name: Install plexmediaserver
  ansible.builtin.dnf:
    name: plexmediaserver
    state: present
  notify: Restart plexmediaserver

# ──────────────────────────────────────────────────────────
# 9. Ensure plex user can read NFS-mounted media
#    The plexmediaserver package creates a 'plex' system user.
#    Adding it to the tbigelow group gives it read access
#    (assuming NFS files are group-readable).
# ──────────────────────────────────────────────────────────
- name: Add plex user to {{ plex_user }} group for media access
  ansible.builtin.user:
    name: plex
    groups: "{{ plex_user }}"
    append: true
  notify: Restart plexmediaserver

# ──────────────────────────────────────────────────────────
# 10. Open firewall port 32400/tcp (Plex Web UI + streaming)
# ──────────────────────────────────────────────────────────
- name: Open Plex port in firewalld
  ansible.posix.firewalld:
    port: 32400/tcp
    permanent: true
    immediate: true
    state: enabled

# ──────────────────────────────────────────────────────────
# 11. Enable and start Plex
# ──────────────────────────────────────────────────────────
- name: Enable and start plexmediaserver
  ansible.builtin.systemd:
    name: plexmediaserver
    enabled: true
    state: started
```

> [!NOTE]
> **`ansible.posix` collection dependency.** This role uses `ansible.posix.authorized_key`, `ansible.posix.mount`, and `ansible.posix.firewalld`. The CI workflow must install this collection:
> ```bash
> ansible-galaxy collection install ansible.posix
> ```

> [!TIP]
> **Plex media permissions explained:** The `plex` system user runs the Plex process. It must be able to `stat` and `read` files under `/mnt/plex/movies` and `/mnt/plex/tvshows`. Adding `plex` to the `tbigelow` group works **only if** the NFS-exported files have group-read permission. If Plex still reports "media not found," check the TrueNAS side — the NFS share may need `mapall=user:group` or the files may need `chmod -R g+rX`.

---

#### [NEW] `ansible/roles/plex_server/handlers/main.yml`

```yaml
---
- name: Restart plexmediaserver
  ansible.builtin.systemd:
    name: plexmediaserver
    state: restarted
```

---

#### [NEW] `ansible/inventory-vms.yml`

Static inventory committed to the repo. Overwritten dynamically by CI from Pulumi outputs, but having a committed version lets you run Ansible manually.

```yaml
all:
  children:
    plex_servers:
      hosts:
        plex:
          ansible_host: 192.168.1.224
          ansible_user: fedora
```

---

#### [NEW] `ansible/playbooks/vm-configure.yml`

```yaml
---
- name: Configure Plex Media Server VM
  hosts: plex_servers
  become: true
  roles:
    - plex_server
```

---

### Stage 4 — GitHub Actions Workflows

Summary: New unified `deploy.yml` orchestrates all three stages sequentially on merge to `main`. The independent deploy jobs in `ansible.yml` and `pulumi.yml` are removed (lint + PR check jobs remain).

---

#### [NEW] `.github/workflows/deploy.yml`

```yaml
name: Deploy

on:
  push:
    branches:
      - main

jobs:
  # ════════════════════════════════════════════════════
  # Stage 1: Run Ansible against Proxmox host
  #   - Updates host packages
  #   - Enables IOMMU/VFIO if needed
  #   - Creates Fedora 43 cloud template (VMID 9000)
  # ════════════════════════════════════════════════════
  deploy-proxmox-prep:
    name: "Stage 1: Proxmox Host Prep"
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Install Ansible + collections
        run: |
          pip install ansible
          ansible-galaxy collection install ansible.posix

      - name: Connect to Tailscale
        uses: tailscale/github-action@v3
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:github-runner

      - name: Setup SSH
        uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.PROXMOX_SSH_KEY }}

      - name: Ensure Proxmox host resolution
        run: |
          echo "192.168.1.223 proxmox" | sudo tee -a /etc/hosts
          echo "192.168.1.223 pve1" | sudo tee -a /etc/hosts

      - name: Add Proxmox to known_hosts
        run: |
          ssh-keyscan -H 192.168.1.223 >> ~/.ssh/known_hosts
          ssh-keyscan -H proxmox >> ~/.ssh/known_hosts
          ssh-keyscan -H pve1 >> ~/.ssh/known_hosts

      - name: Run Ansible Playbook (Proxmox Prep)
        run: ansible-playbook -i inventory.yml site.yml
        working-directory: ansible/

  # ════════════════════════════════════════════════════
  # Stage 2: Run Pulumi to provision VMs
  #   - Clones Fedora template → creates Plex VM (VMID 200)
  #   - Manages TrueNAS VM config
  #   - Exports Plex IP for Stage 3
  # ════════════════════════════════════════════════════
  deploy-pulumi:
    name: "Stage 2: Pulumi VM Provision"
    runs-on: ubuntu-latest
    needs: deploy-proxmox-prep
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-go@v5
        with:
          go-version: '1.25.6'

      - name: Connect to Tailscale
        uses: tailscale/github-action@v3
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:github-runner

      - name: Setup SSH
        uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.PROXMOX_SSH_KEY }}

      - name: Ensure Proxmox host resolution
        run: |
          echo "192.168.1.223 proxmox" | sudo tee -a /etc/hosts
          echo "192.168.1.223 pve1" | sudo tee -a /etc/hosts

      - name: Add Proxmox to known_hosts
        run: |
          ssh-keyscan -H 192.168.1.223 >> ~/.ssh/known_hosts
          ssh-keyscan -H proxmox >> ~/.ssh/known_hosts
          ssh-keyscan -H pve1 >> ~/.ssh/known_hosts

      - name: Pulumi Up
        uses: pulumi/actions@v3
        with:
          command: up
          stack-name: tayvenb13/chalupa-infra/proxmox
          work-dir: pulumi/
        env:
          PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}
          PROXMOX_VE_ENDPOINT: ${{ secrets.PROXMOX_VE_ENDPOINT }}
          PROXMOX_VE_API_TOKEN: ${{ secrets.PROXMOX_VE_API_TOKEN }}
          PROXMOX_VE_SSH_USERNAME: ${{ secrets.PROXMOX_VE_SSH_USERNAME }}

      # Generate VM inventory from Pulumi outputs for Stage 3
      - name: Generate VM inventory
        run: |
          PLEX_IP=$(pulumi stack output plex-ip --stack tayvenb13/chalupa-infra/proxmox)
          cat > inventory-vms.yml <<EOF
          all:
            children:
              plex_servers:
                hosts:
                  plex:
                    ansible_host: ${PLEX_IP}
                    ansible_user: fedora
          EOF
        working-directory: pulumi/
        env:
          PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}

      - name: Upload VM inventory artifact
        uses: actions/upload-artifact@v4
        with:
          name: inventory-vms
          path: pulumi/inventory-vms.yml

  # ════════════════════════════════════════════════════
  # Stage 3: Run Ansible against the new VM
  #   - Installs Plex, NFS mounts, user config, firewall
  #   - Uses the same SSH key as Stages 1 & 2
  # ════════════════════════════════════════════════════
  deploy-vm-configure:
    name: "Stage 3: VM Software Config"
    runs-on: ubuntu-latest
    needs: deploy-pulumi
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Install Ansible + collections
        run: |
          pip install ansible
          ansible-galaxy collection install ansible.posix

      - name: Download VM inventory artifact
        uses: actions/download-artifact@v4
        with:
          name: inventory-vms
          path: ansible/

      - name: Connect to Tailscale
        uses: tailscale/github-action@v3
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:github-runner

      # Same SSH key — authenticates as 'fedora' on the Plex VM
      # because cloud-init injects the matching public key
      - name: Setup SSH
        uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.PROXMOX_SSH_KEY }}

      - name: Add Plex VM to known_hosts
        run: |
          echo "192.168.1.224 plex" | sudo tee -a /etc/hosts
          ssh-keyscan -H 192.168.1.224 >> ~/.ssh/known_hosts

      # The wait_for_connection task in the plex_server role handles
      # waiting for cloud-init. No need for a separate sleep step.
      - name: Run Ansible Playbook (VM Configure)
        run: ansible-playbook -i inventory-vms.yml playbooks/vm-configure.yml
        working-directory: ansible/
```

---

#### [MODIFY] [ansible.yml](file:///Users/tbigelow/Documents/code/chalupa-tech-local/.github/workflows/ansible.yml)

**Remove the `deploy` job** (lines 102–143). Keep the `lint` and `check-and-diff` jobs exactly as they are.

Also update the trigger to only run on `pull_request` (remove the `push` trigger since `deploy.yml` handles that now):

```diff
 on:
-  push:
-    branches:
-      - main
   pull_request:
     branches:
       - main
```

---

#### [MODIFY] [pulumi.yml](file:///Users/tbigelow/Documents/code/chalupa-tech-local/.github/workflows/pulumi.yml)

**Remove the `up` job** (lines 80–126). Keep the `lint` and `preview` jobs exactly as they are.

Same trigger change:

```diff
 on:
-  push:
-    branches:
-      - main
   pull_request:
     branches:
       - main
```

---

### Stage 5 — Documentation & Cleanup

---

#### [NEW] `docs/2026-04-02-add-plex-server-vm.md`

```markdown
# Plex Media Server VM

## Date
April 2, 2026

## What was changed?
- Created Fedora 43 Cloud Base template on Proxmox (VMID 9000) via Ansible
- Added Plex VM (VMID 200) provisioning via Pulumi with:
  - 8 CPU cores, 32 GB RAM, 64 GB disk
  - GPU passthrough (strix_halo_gpu mapping)
  - Cloud-init: static IP 192.168.1.224, SSH key, DNS (192.168.1.1 + 1.1.1.1)
- Created `plex_server` Ansible role for VM configuration:
  - Plex Media Server installation from official RPM repo
  - Two NFS mounts from TrueNAS (/mnt/plex/movies, /mnt/plex/tvshows)
  - User `tbigelow` with SSH + passwordless sudo
  - Firewall port 32400/tcp
- Unified three-stage deploy pipeline in `.github/workflows/deploy.yml`
- Removed deploy jobs from individual `ansible.yml` and `pulumi.yml` workflows
- Cleaned up unused Talos dependency from `go.mod`

## Why was it changed?
To automate the full lifecycle of the Plex Media Server, from VM template creation
through software configuration, using the existing CI/CD pipeline.

## Related PR
PR #XX
```

---

#### [CLEANUP] Remove Talos dependency

```bash
cd pulumi && go mod tidy
```

This removes `github.com/pulumiverse/pulumi-talos/sdk v0.7.1` and its transitive dependencies from `go.mod`/`go.sum`.

---

## File Summary

| Action | File | Stage |
|--------|------|-------|
| MODIFY | `ansible/roles/proxmox_prep/defaults/main.yml` | 1 |
| MODIFY | `ansible/roles/proxmox_prep/tasks/main.yml` | 1 |
| NEW | `ansible/group_vars/all.yml` | 1 |
| NEW | `pulumi/plex.go` | 2 |
| MODIFY | `pulumi/main.go` | 2 |
| CLEANUP | `pulumi/go.mod` (go mod tidy) | 2 |
| NEW | `ansible/roles/plex_server/defaults/main.yml` | 3 |
| NEW | `ansible/roles/plex_server/tasks/main.yml` | 3 |
| NEW | `ansible/roles/plex_server/handlers/main.yml` | 3 |
| NEW | `ansible/inventory-vms.yml` | 3 |
| NEW | `ansible/playbooks/vm-configure.yml` | 3 |
| NEW | `.github/workflows/deploy.yml` | 4 |
| MODIFY | `.github/workflows/ansible.yml` | 4 |
| MODIFY | `.github/workflows/pulumi.yml` | 4 |
| NEW | `docs/2026-04-02-add-plex-server-vm.md` | 5 |

---

## Verification Plan

### On PR (automated — existing workflows)

1. **`ansible-lint`** passes on all new/modified roles and playbooks
2. **`golangci-lint`** passes on `plex.go` (project compiles cleanly)
3. **`pulumi preview`** comment shows the new `plex` VM resource with:
   - Clone from template 9000
   - VMID 200
   - 8 cores, 32 GB RAM, 64 GB disk
   - GPU passthrough hostpci0
   - Cloud-init with static IP 192.168.1.224
4. **`ansible-playbook --check --diff site.yml`** shows template creation tasks (changed)

### On Merge to `main` (automated via `deploy.yml`)

1. Stage 1: Fedora 43 cloud template (VMID 9000) created idempotently on Proxmox
2. Stage 2: Plex VM (VMID 200) cloned from template, booted with cloud-init applied
3. Stage 3: `plexmediaserver` service running; NFS shares mounted at `/mnt/plex/movies` and `/mnt/plex/tvshows`

### Manual verification (post-deploy)

1. `ssh fedora@192.168.1.224` — works with existing SSH key
2. `ssh tbigelow@192.168.1.224` — works after plex_server role runs
3. `http://192.168.1.224:32400/web` — Plex Web UI loads (initial setup wizard)
4. `ls /mnt/plex/movies /mnt/plex/tvshows` — shows TrueNAS media files
5. `systemctl status plexmediaserver` — active (running)
6. `systemctl status qemu-guest-agent` — active (running)
7. Proxmox UI → VM 200 → Summary — shows IP address via guest agent
