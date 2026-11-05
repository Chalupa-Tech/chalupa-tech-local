# PR 2 — Cluster data backups — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every `local-path` PVC on the Talos cluster, the arrs-pg Postgres data, and the OpenBao raft state get scheduled backups onto TrueNAS (via NFS), restorable and alerted on, plus a weekly etcd snapshot — so the "fully destroyable" cluster is actually recreatable without losing app data.

**Architecture:** A new NFS PV/PVC `backups` (TrueNAS `Backups/k8s`, pattern of `media-plexmedia`) in a new `platform/backups` wrapper chart that also deploys `restic/rest-server` (single pod, data on that PVC) and the VolSync operator (chart dependency). A `pvc-backups` values list renders one `ReplicationSource` (restic, `copyMethod: Direct`, hourly/daily) per PVC; local-path's PV node affinity schedules each mover pod onto the volume's node. `arrs-pg` gets a `pg_dumpall` CronJob to the backups PVC; `openbao` gets a raft-snapshot CronJob authenticated through Kubernetes auth + a `snapshot` policy. ESO gets a VMServiceScrape and new VMRules cover sealed OpenBao, non-Ready ExternalSecrets, non-Ready nodes, stale backup CronJobs and VolSync out-of-sync. `restore-drill.yml` gains a cluster job. A weekly `etcd-snapshot.yml` writes `talosctl etcd snapshot` output to pve1's NVMe backup mount.

**Tech Stack:** Helm wrapper charts (repo pattern), VolSync 0.17.0 (`backube/volsync`), restic `rest-server` v0.14.0, CloudNativePG, OpenBao CLI, kube-state-metrics / VictoriaMetrics operator CRs, GitHub Actions, talosctl.

**Spec:** §5.1 items 2, 3, 4, 5 + "Restore drills" + "Alerts"; §6 PR 2; §7 item 1 (TrueNAS dataset — **prerequisite for this PR**).

## Global Constraints

- NFS server for cluster mounts is `10.10.10.40` (workers have storage-subnet NICs; export must allow `10.10.10.0/24`). Path `/mnt/<pool>/Backups/k8s` — pool name is an owner input: values key `backups.nfsPath`.
- Restic repo password: OpenBao `secret/backups/restic` property `password` → ExternalSecret → Secret `restic-repo` with keys `RESTIC_REPOSITORY: rest:http://restic-rest.backups.svc.cluster.local:8000/<pvc-namespace>-<pvc-name>` (per-source secret rendered by the chart) and `RESTIC_PASSWORD`. Policy `backups-read` (`secret/data/backups/*` read) bound to the `external-secrets` role (runbook step).
- VolSync schedules: openbao `0 * * * *`, grafana/audiobookshelf/readmebook `15 * * * *`, victoria-metrics/logs `30 2 * * *`. Retain `hourly: 24, daily: 14, weekly: 8`. `pruneIntervalDays: 7`. `moverSecurityContext.runAsUser: 0` is NOT used — movers run as the PVC's owner UID per app (values key per source).
- OpenBao CronJob: `*/60`→ `5 * * * *`, keeps 48 snapshots at `/backups/openbao/raft-<ts>.snap`; Kubernetes auth role `openbao-snapshot` (SA `openbao-snapshot`, ns `openbao`) with policy `snapshot` (`path "sys/storage/raft/snapshot" { capabilities = ["read"] }`).
- arrs-pg dump CronJob `0 0 * * *` (00:00 MT via `timeZone: America/Denver`), image = the CNPG postgres image already in values, `pg_dumpall -h arrs-pg-rw -U postgres | zstd > /backups/postgres/arrs-pg-<ts>.sql.zst`, keep 14.
- etcd snapshot: weekly `0 9 * * 1`; `talosctl -n 192.168.1.225 etcd snapshot /tmp/etcd.snap` then `scp` to `root@192.168.1.223:/mnt/nvme-backups/talos/etcd-<date>.snap`, keep 8 (prune via `ls -t | tail -n +9 | xargs rm` on pve1 — the only `rm` allowed, scoped to that directory).
- Nothing in this PR may delete a PVC, PV, or CNPG cluster. Drill resources use names suffixed `-drill` and are deleted only by name.

## Review Focus

1. VolSync `Direct` mover pod landing on the wrong node (no affinity) → mount failure loops silently. Task 2's render test asserts no `copyMethod: Snapshot`/`Clone`; the first live sync is the real check (Task 7 verification step).
2. `pg_dumpall` using the superuser secret must not log the password (env from Secret, no `set -x`) — Task 3 test greps the rendered manifest for `PGPASSWORD` only inside `valueFrom`.
3. OpenBao snapshot CronJob with all replicas sealed must fail (not write an empty file) — Task 4 script test `fails_when_sealed`.
4. Backup CronJob staleness alert must key on `kube_cronjob_status_last_successful_time` and fire if the job has *never* run (absent) — Task 5 rule includes `or absent(...)`.
5. Drill restore into a scratch PVC must use a `ReplicationDestination` with `copyMethod: Direct` into a *new* PVC name, never the source PVC — Task 6 workflow step asserts the destination PVC name ends in `-drill`.

---

### Task 1: `platform/backups` chart — NFS PV/PVC, rest-server, VolSync dependency

**Files:**
- Create: `gitops/apps/platform/backups/Chart.yaml` (deps: `volsync` `0.17.0` from `https://backube.github.io/helm-charts/`), `values.yaml`, `templates/namespace.yaml` (PSA baseline), `templates/pv-backups.yaml`, `templates/pvc-backups.yaml`, `templates/restic-rest.yaml` (Deployment + Service `restic-rest` :8000, image `restic/rest-server:0.14.0`, args `--path /data --no-auth --append-only`), `templates/restic-externalsecret.yaml`
- Modify: `gitops/bootstrap/applicationsets/platform.yaml` — none needed (auto-discovered).

**Interfaces:**
- Values: `backups.nfsServer: 10.10.10.40`, `backups.nfsPath: /mnt/CHANGEME/Backups/k8s`, `backups.size: 2Ti`, `resticRest.image.repository/tag`.
- Produces: namespace `backups`, PVC `backups/backups` (RWX, NFS), Service `restic-rest.backups.svc.cluster.local:8000`, Secret `backups/restic-repo-password` (key `password`).

- [ ] **Step 1:** Write chart files following `gitops/apps/platform/openbao` (namespace template, wrapper layout) and `gitops/apps/media/nzbget/templates/pv-plexmedia.yaml` (PV mount options).
- [ ] **Step 2: Render like CI.** Run: `helm dependency update gitops/apps/platform/backups && helm template backups gitops/apps/platform/backups --api-versions external-secrets.io/v1 | kubeconform -strict -ignore-missing-schemas -summary -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'` Expected: `Errors: 0`.
- [ ] **Step 3: Commit** `feat(backups): platform/backups chart — NFS backup volume, restic rest-server, VolSync`.

### Task 2: `pvc-backups` ReplicationSources

**Files:**
- Create: `gitops/apps/platform/pvc-backups/Chart.yaml` (no deps), `values.yaml` (list `sources:` of `{namespace, pvc, schedule, runAsUser, fsGroup}` for: openbao data-openbao-0/1/2, grafana/grafana, media/audiobookshelf-config, media/audiobookshelf-metadata, media/readmebook-config, media/readmebook-cache, vm-system/vmsingle-vmsingle-chalupa, vl-system/server-volume-vl-system-victoria-logs-single-server-0), `templates/replicationsource.yaml` (range), `templates/restic-secret.yaml` (one Secret per source via ExternalSecret `template` referencing the shared password), `tests/test_render.sh`

**Interfaces:**
- Each `ReplicationSource` named `<pvc>` in the PVC's namespace: `sourcePVC`, `trigger.schedule`, `restic.repository: restic-<pvc>`, `restic.copyMethod: Direct`, `restic.retain`, `restic.pruneIntervalDays: 7`, `restic.moverSecurityContext: {runAsUser, fsGroup}` from values.

- [ ] **Step 1: Write the failing render test:** asserts every PVC in the Global Constraints list appears exactly once as a ReplicationSource, `copyMethod: Direct` everywhere, no `Snapshot`/`Clone`, secrets' `RESTIC_REPOSITORY` end with `/<namespace>-<pvc>`.
- [ ] **Step 2: Run → FAIL.** 
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Test + kubeconform** (VolSync CRDs are in datree catalog: `volsync.backube/ReplicationSource_v1alpha1`). Expected: `PASS`, `Errors: 0`.
- [ ] **Step 5: Commit** `feat(backups): VolSync ReplicationSources for every local-path PVC`.

### Task 3: arrs-pg logical dumps

**Files:**
- Create: `gitops/apps/media/arrs-pg/templates/dump-cronjob.yaml`, `templates/backups-pvc.yaml` (PVC `media/backups-k8s` bound to a second PV `backups-k8s-media` → same NFS path; NFS allows multiple PVs to one export), `files/pg-dump.sh`, `tests/test_pg_dump.sh`
- Modify: `gitops/apps/media/arrs-pg/values.yaml` (`dump.schedule`, `dump.keep: 14`)

**Interfaces:**
- `pg-dump.sh`: env `PGHOST=arrs-pg-rw`, `PGUSER`/`PGPASSWORD` from Secret `arrs-pg-superuser`, `OUT_DIR=/backups/postgres`, `KEEP=14`; writes `arrs-pg-<YYYYmmdd-HHMM>.sql.zst`, prunes to KEEP newest, verifies with `zstd -t`; exit non-zero on any failure.

- [ ] **Step 1: Failing script test** (stub `pg_dumpall`, real `zstd`): `writes_and_prunes` (16 old files → 14 remain + new one), `fails_when_dump_fails` (stub exits 1 → no file left, exit 1), `no_password_in_logs`.
- [ ] **Step 2: Run → FAIL.** **Step 3: Implement.** **Step 4: Test + render + kubeconform.** **Step 5: Commit** `feat(arrs-pg): nightly pg_dumpall to the backups volume`.

### Task 4: OpenBao raft snapshots

**Files:**
- Create: `gitops/apps/platform/openbao/templates/snapshot-cronjob.yaml` (SA `openbao-snapshot`, CronJob, PVC `openbao/backups-k8s` + PV), `files/raft-snapshot.sh`, `tests/test_raft_snapshot.sh`
- Create: `scripts/openbao/policies/snapshot.hcl`; Modify: `scripts/openbao/README.md` (role creation runbook: `bao write auth/kubernetes/role/openbao-snapshot bound_service_account_names=openbao-snapshot bound_service_account_namespaces=openbao token_policies=snapshot ttl=15m`)

**Interfaces:**
- `raft-snapshot.sh`: logs in with `bao write -field=token auth/kubernetes/login role=openbao-snapshot jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token`, `bao operator raft snapshot save /backups/openbao/raft-<ts>.snap`, verifies size > 0 and `bao operator raft snapshot inspect`, prunes to 48. `BAO_ADDR=http://openbao-active.openbao.svc:8200`.

- [ ] **Step 1: Failing test** (stub `bao`): `saves_and_prunes`, `fails_when_sealed` (stub `bao status` → sealed, login fails → exit 1, no file), `fails_on_empty_snapshot`.
- [ ] **Step 2–5** as above. Commit `feat(openbao): hourly raft snapshots via Kubernetes auth`.

### Task 5: Scrapes + alert rules

**Files:**
- Create: `gitops/apps/platform/external-secrets/templates/vmservicescrape.yaml` (port `metrics` 8080 on the ESO controller Service — verify the Service exposes it; if not, a `VMPodScrape` on the pod port), `gitops/apps/observability/vmalert/templates/rules/cluster-backups.yaml`, `rules/cluster-health.yaml`

**Interfaces (rules):**
- `OpenBaoSealed`: `kube_pod_container_status_ready{namespace="openbao",pod=~"openbao-[0-9]+"} == 0` for 15m, critical.
- `ExternalSecretNotReady`: `externalsecret_status_condition{condition="Ready",status="True"} == 0` for 30m, warning.
- `KubeNodeNotReady`: `kube_node_status_condition{condition="Ready",status="true"} == 0` for 10m, critical.
- `BackupCronJobStale`: `(time() - kube_cronjob_status_last_successful_time{cronjob=~"arrs-pg-dump|openbao-snapshot"}) > 2 * 86400 or absent(kube_cronjob_status_last_successful_time{cronjob="arrs-pg-dump"}) or absent(kube_cronjob_status_last_successful_time{cronjob="openbao-snapshot"})` for 1h, warning.
- `VolSyncOutOfSync`: `volsync_volume_out_of_sync == 1` for 2h, warning (needs a VMPodScrape on the volsync metrics port 8443/https — if TLS makes it awkward, scrape via the operator's `--metrics-bind-address` set to `:8080` insecure in the chart values).

- [ ] Steps: write, render + kubeconform (skip VM kinds as `gitops.yml` does), commit `feat(vmalert): cluster health + backup staleness rules; ESO/VolSync scrapes`.

### Task 6: Cluster restore drill + etcd snapshot workflow

**Files:**
- Modify: `.github/workflows/restore-drill.yml` — new job `cluster-drill` (needs Pulumi kubeconfig like deploy.yml Stage 4): (a) apply a `ReplicationDestination` `openbao-drill` in ns `backups` restoring repo `openbao-data-openbao-0` into new PVC `openbao-drill-restore` (`copyMethod: Direct`), wait for `.status.latestMoverStatus.result == Successful`, run a one-shot Pod that lists `/data` and asserts `raft/raft.db` exists, delete the RD + PVC by name; (b) `kubectl -n media create -f` a CNPG `Cluster` `arrs-pg-drill` (1 instance, 5Gi, `bootstrap.initdb`), wait Ready, `kubectl exec` the newest dump through `zstd -dc | psql`, assert `SELECT count(*) FROM pg_database WHERE datname='radarr_main'` = 1, delete `arrs-pg-drill`; (c) newest raft snapshot passes `bao operator raft snapshot inspect` in a `openbao-0` exec.
- Create: `.github/workflows/etcd-snapshot.yml` (weekly; `talosctl` from `pulumi stack output talosconfig --show-secrets`; scp to pve1 NVMe mount; prune to 8).

- [ ] Steps: write, `actionlint`, commit `ci: cluster restore drill (VolSync, CNPG) + weekly etcd snapshot`.

### Task 7: Docs, runbook, PR

- Create `docs/2026-11-04-cluster-backups.md` (what, where, restore procedures per data type, the OpenBao runbook steps: `apply-policy.sh snapshot`, `apply-policy.sh backups-read`, role creation, `kv-put.sh backups/restic password=<random>`), update `scripts/openbao/README.md`, `README.md` Backups section.
- Verification: all render tests + script tests + `actionlint`; after merge: first VolSync sync `Successful` for every source (`kubectl get replicationsource -A`), first CronJob runs green, drill run green.
- PR `feat: cluster data backups — VolSync/restic, pg_dumpall, OpenBao raft snapshots, etcd (PR 2/5)` stacked on PR 1.
