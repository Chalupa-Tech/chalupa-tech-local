# Cluster data backups: VolSync/restic, pg_dumpall, OpenBao raft, etcd

**Date:** 2026-11-04
**PR:** #TBD (PR 2 of the auto-patching series —
`docs/superpowers/specs/2026-11-04-auto-patching-design.md` §5.1 items 2–5)

## Why

The Talos cluster is "fully destroyable and recreatable", but every PVC on
it is `local-path` (node-local directories, no CSI snapshots): OpenBao's
raft state, Grafana, audiobookshelf, readmebook, VictoriaMetrics and
VictoriaLogs data, plus the arrs-pg Postgres cluster. Until this PR none of
it was backed up anywhere; losing a worker VM meant losing that data.

## What backs up what

Everything lands on the TrueNAS export **`/mnt/AppData/Backups/k8s`**
(NFS from `10.10.10.40`; owner creates the dataset and export — see below).

| Data | Mechanism | Schedule | Retention | Where on the export |
|---|---|---|---|---|
| every local-path PVC (10: openbao ×3, grafana, audiobookshelf ×2, readmebook ×2, vmsingle, victoria-logs) | VolSync `ReplicationSource` (restic, `copyMethod: Direct`, mover runs as the UID owning the files) → restic REST server `restic-rest.backups:8000` | hourly (openbao :00; grafana/media :15), daily 02:30 (metrics/logs) | 24 h / 14 d / 8 w, prune weekly | `restic/<namespace>-<pvc>/` |
| arrs-pg (Postgres 18) | CronJob `arrs-pg-dump`: `pg_dumpall --no-role-passwords` as superuser, gzip (the CNPG image has no zstd), `gzip -t` verified | 00:00 America/Denver | 14 | `postgres/arrs-pg-<ts>.sql.gz` |
| OpenBao raft | CronJob `openbao-snapshot`: `bao operator raft snapshot save` via Kubernetes auth (role `openbao-snapshot`, policy `snapshot`), archive verified with `sha256sum -c SHA256SUMS` (OpenBao has no `snapshot inspect`) | hourly :05 | 48 | `openbao/raft-<ts>.snap` |
| etcd | `.github/workflows/etcd-snapshot.yml`: `talosctl etcd snapshot` → `pve1:/mnt/nvme-backups/talos/` | Mondays 09:00 UTC | 8 | (NVMe on pve1) |

Charts: `gitops/apps/platform/backups` (NFS PV/PVC, `restic/rest-server`
0.14.0, restic password ExternalSecret), `gitops/apps/platform/pvc-backups`
(VolSync 0.17.0 operator + one ReplicationSource + restic Secret per PVC
from a values list — adding a PVC is one entry; operator and CRs share the
app so the CRDs land in the same sync),
`gitops/apps/media/arrs-pg` (dump CronJob + its own PV/PVC onto the same
export), `gitops/apps/platform/openbao` (snapshot CronJob + PV/PVC).

## Alerts (vmalert)

`OpenBaoSealed` (replica not ready 15 m, critical), `ExternalSecretNotReady`
(30 m), `ExternalSecretMetricsAbsent`, `KubeNodeNotReady` (10 m, critical),
`BackupCronJobStale` (no success in 2 d), `BackupCronJobNeverSucceeded`,
`VolSyncOutOfSync` (missed schedule, 2 h), `VolSyncMetricsAbsent`.
New scrapes: ESO controller (`external-secrets` VMServiceScrape) and the
VolSync operator (`backups/volsync`, HTTPS with self-signed cert).

## Restore drill

`restore-drill.yml` gained a `cluster-drill` job (`scripts/k8s/restore-drill.sh`,
monthly after the Proxmox drill): VolSync `ReplicationDestination` of
`openbao/data-openbao-0` into a scratch PVC (asserts `raft/raft.db`), a
throwaway CNPG cluster `arrs-pg-drill` loaded from the newest dump (asserts
`radarr_main` exists), and a `sha256sum -c SHA256SUMS` check of the newest
raft snapshot archive (OpenBao's CLI has no `snapshot inspect`; the script
originally called it and failed on every run — fixed 2026-11-07). Everything it creates is named `*-drill`; it deletes only
those names, also on failure.

## Restoring for real

- **A PVC:** create a `ReplicationDestination` (copy the drill's manifest in
  `scripts/k8s/restore-drill.sh`, `restic.repository: restic-<pvc>`,
  `destinationPVC: <new pvc>`), wait for `latestMoverStatus.result:
  Successful`, point the workload at the new PVC (or `rsync` into the
  original). Older points in time: set `restic.previous`/`restoreAsOf`.
- **arrs-pg:** `gzip -dc postgres/arrs-pg-<ts>.sql.gz | psql -h arrs-pg-rw -U postgres`
  (a full `pg_dumpall` without role passwords; CNPG's `managed.roles` and
  the ESO-managed secrets set the passwords on a fresh cluster).
- **OpenBao:** `bao operator raft snapshot restore -force openbao/raft-<ts>.snap`
  on the active node (same unseal keys), then unseal.
- **etcd:** `talosctl -n 192.168.1.225 bootstrap --recover-from=etcd-<ts>.snap`
  on a fresh control plane (Talos docs "Disaster recovery").

## Owner steps (one-time, before merge or right after)

1. TrueNAS: dataset `AppData/Backups` with children `k8s`, `proxmox`,
   `homeassistant`; NFS export of `AppData/Backups` (or each child) to
   `10.10.10.0/24` and `192.168.1.0/24` with **Mapall User/Group = root**
   (like the PlexMedia export): the writers run as uids 26, 100 and 1000 and
   `fsGroup` does nothing on NFS, so every client must be squashed to one
   identity. **Daily ZFS snapshot task on it (keep 30)** — this, not
   rest-server append-only mode, is what protects history (restic's
   forget/prune need delete). Then set `proxmox_prep_backup_nfs_export:
   /mnt/AppData/Backups/proxmox` (PR 1) to move the Proxmox guests there.
   Sync order on first merge: `backups` (PV/PVC, rest-server) → `pvc-backups`
   (operator + sources) — ArgoCD retries 5× over ~12 min; if `pvc-backups`
   ends `Failed` because the export was not there yet, hit Sync once.
2. OpenBao (runbook in `scripts/openbao/README.md`):
   `apply-policy.sh backups-read` + rebind the `external-secrets` role with
   it; `apply-policy.sh snapshot` + create role `openbao-snapshot`;
   `kv-put.sh backups/restic password=<64 random chars>` — **store the
   password in 1Password; without it every restic repository is unreadable.**
3. After the first hour: `kubectl get replicationsource -A` shows
   `Successful` for all ten; `kubectl -n media get jobs`, `kubectl -n openbao
   get jobs` show the CronJobs green; then `gh workflow run restore-drill.yml`.

## Notes

- `local-path` volumes are hostPath directories: `fsGroup` is not applied,
  so each mover runs as the UID that owns the files (values comment lists
  them). VictoriaMetrics writes as root, hence the `volsync.backube/
  privileged-movers: "true"` annotation on `vm-system`.
- The NFS export path appears in three values files (`platform/backups`,
  `media/arrs-pg`, `platform/openbao`); keep them identical.
- Restic REST is not append-only (VolSync's forget/prune need delete); the
  dataset's ZFS snapshots are the tamper/mistake protection. The dump and
  snapshot CronJobs mount the export root too, so the same applies to them.
- readmebook's movers run as root (one 0600 root-owned file on its volume);
  the `media` ApplicationSet sets `volsync.backube/privileged-movers` on the
  namespace via `managedNamespaceMetadata`.

**2026-11-05 fix:** VolSync 0.17 crash-looped after the merge (`no matches for kind VolumeSnapshot`): it watches the VolumeSnapshot kinds at startup even for `copyMethod: Direct`. The three `snapshot.storage.k8s.io` CRDs (external-snapshotter v8.7.0, CRDs only — no snapshot controller) are now vendored in `gitops/apps/platform/pvc-backups/crds/`.
