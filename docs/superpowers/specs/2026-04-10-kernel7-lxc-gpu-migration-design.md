# Plex VM → LXC Migration with Kernel 7 + GPU Sharing

## Context

GPU passthrough to the Plex VM has been unreliable on the Strix Halo iGPU — the initial attempt (PR #28) was removed (PR #32) because `qm start` hung due to the iGPU only supporting pm/bus reset (no FLR). The host-level VFIO workarounds on `feat/gpu-passthrough-host-prep` address this for exclusive VM passthrough, but the actual goal is **GPU sharing** — allowing multiple containers (and potentially the host) to share the iGPU simultaneously.

GPU sharing requires the `amdgpu` driver loaded on the host, which is incompatible with VFIO binding. This means abandoning the VFIO approach entirely and migrating Plex from a full VM to an LXC container with `/dev/dri` device bind mounts.

Additionally, upgrading to Linux kernel 7.0 (opt-in for PVE 9, default in 9.2) improves Strix Halo GPU support.

## Approach: Aggressive 2-PR Migration

### PR A — Host Prep

**Branch**: new from `main` (abandon `feat/gpu-passthrough-host-prep`)

#### Ansible `proxmox_prep` role changes

**`ansible/roles/proxmox_prep/defaults/main.yml`:**
- `proxmox_prep_gpu_passthrough_enabled: false` — disables VFIO binding tasks
- `proxmox_prep_kernel_7_enabled: true` — new flag
- `proxmox_prep_lxc_template_name: "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"` — new var
- `proxmox_prep_lxc_template_storage: "local"` — new var

**`ansible/roles/proxmox_prep/tasks/main.yml`** — new tasks:
1. Remove stale VFIO config files (`/etc/modprobe.d/blacklist-gpu.conf`, `/etc/modprobe.d/vfio-pci.conf`) if present — idempotent cleanup from abandoned branch
2. Remove `initcall_blacklist=sysfb_init` from GRUB cmdline if present
3. Enable `pve-test` apt repository
4. Install `proxmox-kernel-7.0` package
5. Pin kernel 7 as default boot kernel
6. Download Ubuntu 24.04 LTS container template via `pveam download`

Existing handlers (`Update GRUB`, `Update initramfs`, `Prompt reboot`) are sufficient.

#### Post-merge manual steps
1. SSH to `pve1`, reboot
2. Verify `uname -r` shows kernel 7.x
3. Verify `lspci -nnk -s c7:00.0` shows `Kernel driver in use: amdgpu`
4. Verify `ls /dev/dri/renderD128` exists
5. Verify both VMs running: `qm list`

#### Risk: Low
Old kernel remains in GRUB as fallback. Existing VMs are unaffected. VFIO cleanup is idempotent.

---

### PR B — Full Migration (LXC + Ansible + Cutover)

**Branch**: `feat/lxc-plex-migration`

#### Pre-merge manual steps (critical, must happen in order)

1. **Backup Plex data** from the VM:
   ```bash
   ssh fedora@192.168.1.224 sudo systemctl stop plexmediaserver
   ssh fedora@192.168.1.224 sudo tar czf /tmp/plex-backup.tar.gz /var/lib/plexmediaserver/
   scp fedora@192.168.1.224:/tmp/plex-backup.tar.gz ~/
   ```

2. **Destroy the old VM** (frees VMID 200 and IP .224):
   ```bash
   ssh root@192.168.1.223 "qm stop 200 && qm destroy 200"
   ```

3. **Remove VM from Pulumi state** (find URN with `pulumi stack export | jq '.deployment.resources[] | select(.type | contains("VirtualMachine")) | .urn'`):
   ```bash
   cd pulumi && pulumi state delete <plex-server-URN>
   ```

4. Merge PR B — CI pipeline creates LXC and configures it.

5. **Restore Plex data** on the new LXC:
   ```bash
   scp ~/plex-backup.tar.gz root@192.168.1.224:/tmp/
   ssh root@192.168.1.224 'cd / && tar xzf /tmp/plex-backup.tar.gz && chown -R plex:plex /var/lib/plexmediaserver/ && systemctl restart plexmediaserver'
   ```

#### Pulumi changes

**Delete `pulumi/plex.go`** — removes Fedora VM definition.

**New `pulumi/plex_lxc.go`** — `ct.NewContainer()`:
- VMID: 200
- OS: Ubuntu 24.04 LTS template (`local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst`)
- CPU: 8 cores
- Memory: 8GB dedicated (LXC overhead is minimal; Plex doesn't need 32GB)
- Disk: 16GB root on `local-lvm`
- Network: Bridge `vmbr0`, static IP `192.168.1.224/24`, gateway `192.168.1.1`
- GPU: `DevicePassthroughs` for `/dev/dri/renderD128` and `/dev/dri/card0`
- Features: Nesting enabled (for systemd), NFS mount type allowed
- Boot order: 3 (after TrueNAS)
- Unprivileged: true
- Started: true, OnBoot: true
- Initialization: root SSH keys, DNS (`192.168.1.1`, `1.1.1.1`)
- `IgnoreChanges`: `["started"]` to avoid restart drift (consistent with VM pattern)

**Update `pulumi/main.go`**: Replace `createPlexVM()` with `createPlexLXC()`. Add `ct` package import.

No provider upgrade needed — v7.13.0 already has `ct.Container`.

#### Ansible changes

**Rewrite `ansible/roles/plex_server/` in place** for Ubuntu:

| Task | Fedora (current) | Ubuntu (new) |
|------|-------------------|--------------|
| Package manager | `dnf` | `apt` |
| Guest agent | Install `qemu-guest-agent` | Remove (not needed in LXC) |
| NFS client | `nfs-utils` | `nfs-common` |
| Plex repo | `rpm_key` + `yum_repository` (repo.plex.tv/rpm) | `apt_key` + `apt_repository` (downloads.plex.tv/repo/deb) |
| Firewall | `firewalld` + port 32400 | `ufw` allow 32400/tcp |
| Sudo group | `wheel` | `sudo` |
| **NEW**: VA-API drivers | — | Install `mesa-va-drivers`, `libva2`, `vainfo` |
| **NEW**: GPU access | — | Add `plex` user to `video` + `render` groups |

**`ansible/roles/plex_server/defaults/main.yml`**: Update Plex repo URL to DEB repo, GPG key URL, package names.

**`ansible/inventory-vms.yml`**: Change `ansible_user: fedora` → `ansible_user: root`.

**`ansible/playbooks/vm-configure.yml`**: Remove `gather_facts: false` workaround (no cloud-init delay in LXC).

#### CI/CD pipeline changes

**`.github/workflows/deploy.yml`**:
- Stage 2: No explicit change needed — Pulumi code change handles LXC creation automatically
- Stage 3: Update `ansible_user` in inventory generation from `fedora` to `root`

#### Post-merge verification
1. SSH to `root@192.168.1.224`
2. Verify Plex is running: `systemctl status plexmediaserver`
3. Verify GPU access: `vainfo` shows AMD device
4. Verify NFS mounts: `mount | grep nfs`
5. Open Plex UI at `192.168.1.224:32400/web`
6. Play a video requiring transcode — confirm "(hw)" indicator in Plex dashboard

#### Risk: High
- **Downtime**: ~30-60 minutes (VM destroy → CI pipeline → Plex restore)
- **Biggest risk**: If LXC GPU passthrough doesn't work, Plex is down until debugged
- **Mitigation**: Plex backup tar allows VM recreation as rollback
- **Pulumi state surgery**: Required but straightforward

---

## Architecture After Migration

```
Proxmox Host (pve1, 192.168.1.223)
├── Kernel 7.0 with amdgpu driver loaded
├── /dev/dri/renderD128 (shared GPU)
│
├── TrueNAS VM (192.168.1.40)
│   ├── 4 cores, 32GB RAM
│   ├── HBA passthrough (2 mappings)
│   ├── Boot order: 1
│   └── pulumi.Protect(true)
│
└── Plex LXC (VMID 200, 192.168.1.224)
    ├── Ubuntu 24.04 LTS (unprivileged)
    ├── 8 cores, 8GB RAM, 16GB disk
    ├── GPU: /dev/dri/renderD128 + /dev/dri/card0
    ├── NFS: TrueNAS Movies + TVShows
    ├── VA-API hardware transcoding
    └── Boot order: 3
```

## CI/CD Pipeline After Migration

1. **Stage 1** — Ansible prepares Proxmox host (IOMMU, kernel 7, Ubuntu LXC template)
2. **Stage 2** — Pulumi provisions TrueNAS VM + Plex LXC, exports Plex IP
3. **Stage 3** — Ansible configures Plex LXC (packages, NFS, GPU drivers, firewall)

## Files Modified

| File | Action |
|------|--------|
| `ansible/roles/proxmox_prep/defaults/main.yml` | Edit: disable VFIO, add kernel/template vars |
| `ansible/roles/proxmox_prep/tasks/main.yml` | Edit: add VFIO cleanup, kernel install, template download |
| `pulumi/plex.go` | Delete |
| `pulumi/plex_lxc.go` | Create |
| `pulumi/main.go` | Edit: swap createPlexVM → createPlexLXC, add ct import |
| `ansible/roles/plex_server/tasks/main.yml` | Rewrite for Ubuntu |
| `ansible/roles/plex_server/defaults/main.yml` | Rewrite for Ubuntu/DEB |
| `ansible/inventory-vms.yml` | Edit: ansible_user fedora → root |
| `ansible/playbooks/vm-configure.yml` | Edit: remove gather_facts workaround |
| `.github/workflows/deploy.yml` | Edit: update Stage 3 ansible_user |
| `CLAUDE.md` | Edit: update architecture section |
| `docs/` | Create: migration doc with rationale |

## Rollback Strategy

**PR A rollback**: Reboot into old kernel via GRUB menu. Re-enable `proxmox_prep_gpu_passthrough_enabled: true` and re-run pipeline.

**PR B rollback**: Restore Plex VM by reverting PR code changes, running `pulumi up` to recreate VM, and restoring from the backup tar. Estimated recovery: 1-2 hours.
