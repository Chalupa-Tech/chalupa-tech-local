# Fix: Proxmox guest backups had been failing since March (and nothing noticed)

**Date:** 2026-11-04
**PR:** #TBD (PR 1 of the auto-patching series —
`docs/superpowers/specs/2026-11-04-auto-patching-design.md`)

## Symptom

The only vzdump job on `pve1` (`backup-af8b79f5-6e9a`, created by hand on
2026-03-07, `sun 01:00`, all guests) pointed at a storage named
`local_backups` that was never created. Every weekly run ended with

```
TASK ERROR: could not activate storage 'local_backups': storage 'local_backups' does not exist
```

No notification target was configured, so the failure went to local mail.
Result: **zero backups of TrueNAS (101), Home Assistant (250), Plex (200)
or the Tailscale LXC (100) for eight months**, discovered during the
2026-11-04 CVE/patch audit (`docs/2026-11-04-cve-audit.md`).

## What changed

- **Backup targets.** The TrueNAS VM must not be backed up to TrueNAS, so
  `proxmox_prep` now carves a 1 TB ext4 LV (`backups`) from the spare
  4 TB NVMe (`nvme1n1`, VG `nvme_4tb_front`, which had no LVs), mounts it
  at `/mnt/nvme-backups` and registers it as dir storage `nvme-backups`.
  A second storage, `truenas-backups` (NFS from `192.168.1.40`), is
  registered as soon as `proxmox_prep_backup_nfs_export` is set.
- **Two declarative jobs** (`ansible/roles/proxmox_prep/tasks/backups.yml`
  via `files/ensure-vzdump-job.sh`, idempotent through `pvesh`):
  `nightly-truenas` (101 → `nvme-backups`) and `nightly-guests`
  (100, 200, 250 → `truenas-backups`, or `nvme-backups` until the export
  exists). Daily 01:00, snapshot mode, zstd, `keep-last=7,keep-weekly=4`.
  The broken legacy job is deleted. Talos VMs are not backed up — they are
  recreatable from the pipeline and their persistent data gets its own
  backup path in PR 2.
- **Observability.** A vzdump hook (`files/vzdump-metrics-hook.sh`, wired
  through `script:` in `/etc/vzdump.conf`) writes
  `pve_backup_last_success_timestamp{vmid,storage}` and
  `pve_backup_last_failure_timestamp{vmid,storage}` to the node-exporter
  textfile dir already scraped as job `proxmox-host`. New VMRule
  `backups` (`gitops/apps/observability/vmalert/templates/rules/backups.yaml`):
  `ProxmoxBackupStale` (>36 h), `ProxmoxBackupFailed` (also for a guest
  that has *never* succeeded), `ProxmoxBackupNeverSucceeded` (one per
  expected VMID, from `values.yaml` `backups.expectedVmids`; fires until
  that guest's first success — by design), `ProxmoxRestoreDrillStale`
  (>40 d), `ProxmoxRebootRequired` (>14 d).
- **Restore drill.** `.github/workflows/restore-drill.yml` runs
  `scripts/proxmox/restore-drill.sh` on `pve1` monthly: restores the newest
  250 and 200 archives to scratch VMIDs **9250/9200** on `local-lvm`
  (never started), immediately strips `onboot`/`startup`/NICs so a
  lingering clone can never boot with the source's IP, checks for a disk,
  destroys them (also on failure),
  `zstd -t`s the newest 101/100 archives, and writes
  `pve_restore_drill_last_success_timestamp`. Failure opens/updates a
  GitHub issue labelled `backup-drill-failed`.
- **Stage 1 can no longer patch the host.** The unconditional
  `apt dist-upgrade` at the top of `proxmox_prep` is gone (unattended-
  upgrades and the maintenance window own that in PR 3), and the
  `pve-test` apt source is removed (`docs/2026-05-26-remove-kernel7-optin.md`
  already said it should be).
- **HAOS image pin fixed.** `haos_image_filename` was hard-pinned to 17.3
  while `haos_version` was 18.2, so the next Stage 1 run would have 404'd
  before reaching the backup tasks. Filename and checksum now derive from
  `haos_version` (checksum via the release `SHA256SUMS`, which exists from
  18.4 on — hence the bump to 18.4 here, in both Ansible and Pulumi config).

## Owner follow-ups

1. After the first merge, confirm a run: `ssh root@192.168.1.223 'cat
   /var/lib/prometheus/node-exporter/vzdump.prom'` the morning after, or
   wait for `ProxmoxBackupMetricsAbsent` to resolve.
2. To move the non-TrueNAS guests onto TrueNAS: create dataset
   `Backups/proxmox`, NFS-export it to `192.168.1.0/24` (maproot root), set
   `proxmox_prep_backup_nfs_export: /mnt/<pool>/Backups/proxmox` in
   `ansible/roles/proxmox_prep/defaults/main.yml`, merge.
3. Kick the drill once by hand: `gh workflow run restore-drill.yml`.
4. When the guests move to `truenas-backups`, the 7+4 archives of 100/200/250
   already on `nvme-backups` are no longer pruned by any job — delete them
   once from Datacenter → Storage → nvme-backups → Backups (or
   `pvesm list nvme-backups --vmid <id>` + `pvesm free <volid>`).

## Verification (local, 2026-11-04)

`ansible-lint` clean; `ansible-playbook -i inventory.yml site.yml --check
--diff` against `pve1`: LV/scripts/vzdump.conf/jobs reported `changed`, the
live legacy job untouched, `failed=0`. Unit tests:
`ansible/roles/proxmox_prep/files/tests/*.sh`, `scripts/proxmox/tests/*.sh`
(stubbed `pvesh`/`qm`/`pct`/`pvesm`). `helm template` + kubeconform for
the vmalert chart; `actionlint` for the workflow.
