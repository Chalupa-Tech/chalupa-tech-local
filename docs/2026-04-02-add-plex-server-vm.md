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
