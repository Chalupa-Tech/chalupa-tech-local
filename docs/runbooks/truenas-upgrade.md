# Runbook: TrueNAS SCALE version upgrade (manual, backup-gated)

TrueNAS is the one system in the estate that is **not** auto-patched: every
other backup and every NFS mount depends on it, and SCALE upgrades reboot the
storage. Upstream publishes a release roughly monthly; do this when the TrueNAS UI
shows one (once PR #309's alert-list exporter lands, add a
`TrueNASUpdateAvailable` rule on its `truenas_alert_active` metric so the
signal reaches Discord). Budget 30 minutes; media playback and the arr stack are down
for the reboot.

## 0. Preconditions (all automated — just check them)

| Check | Where |
|---|---|
| Last night's vzdump of VM 101 succeeded (< 30 h) | `ssh root@192.168.1.223 'grep vmid=\"101\" /var/lib/prometheus/node-exporter/vzdump.prom'` or no `ProxmoxBackupStale` alert |
| No backup or drill is running | `gh run list --workflow restore-drill.yml --limit 1`; CronJobs `arrs-pg-dump` / `openbao-snapshot` idle (`kubectl get jobs -A`) |
| Cluster healthy | `gh workflow run health-check.yml` → green |

## 1. Export the configuration

TrueNAS UI → System → General → **Manage Configuration → Download File**
(include the secret seed). Store it next to the vzdump archives:
`/mnt/nvme-backups/truenas-config/` on pve1 (`scp` it there) — the boot-disk
vzdump also contains it, this is the quick-restore copy.

## 2. Apply the update

System → Update → choose the release → **Apply pending update** with
"Create boot environment" (default). The reboot takes ~3 minutes; NFS clients
(`hard` mounts) block and resume by themselves.

## 3. Verify

1. `ssh root@192.168.1.223 showmount -e 192.168.1.40` lists the exports.
2. `gh workflow run health-check.yml` → green (Plex `/identity`, TrueNAS NFS,
   ArgoCD apps; media pods recover once the NFS mount returns), and
   `kubectl -n media get pvc media-plexmedia` is `Bound`.
3. Watch for `TrueNASMetricsStale` / `TrueNASAlert` (PR #309 rules) for an hour.

## 4. Rollback

System → Boot → activate the previous boot environment → reboot. Data pools
are untouched by a boot-environment rollback. If the VM does not boot at all:
restore the latest `vzdump-qemu-101-*` archive from `nvme-backups` onto VMID
101 (Datacenter → nvme-backups → Backups → Restore), keeping the HBA
passthrough mappings (they live in the VM config, which the archive includes).

## Why not automate this one

A failed TrueNAS boot takes every backup target, the media share and the
cluster's backup volume with it, and recovery needs the Proxmox console. The
blast radius is the whole estate and the frequency is monthly: a human in the
loop costs less than the automation would.
