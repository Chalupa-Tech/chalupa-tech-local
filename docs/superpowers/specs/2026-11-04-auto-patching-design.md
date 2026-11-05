# Auto-patching with auto-recovery (no data loss) — design

**Date:** 2026-11-04
**Status:** proposed (awaiting owner approval)
**Scope:** everything in the chalupa-tech-local estate except the Unifi gateway
(already auto-patches). The old Raspberry Pi K3s cluster (`chalupa-infra`
repo) is assumed decommissioned — no `tpi*` nodes are on the tailnet.

## 1. Intent

Recent CVEs prompted an audit. The audit (section 2) found that only the
Kubernetes app layer is kept current (Renovate + ArgoCD), and that **no
host, VM or LXC in the estate has a working backup**. Patching anything
without a restorable backup violates the "no data loss" requirement, so the
design is ordered: backups first, then patching rings, then recovery
automation, and every ring gets a verification step and an alert.

## 2. Current state (verified live 2026-11-04 unless marked)

| Component | Running | Patch path today | Gap |
|---|---|---|---|
| Proxmox host `pve1` (PVE 9.2.20, Debian 13) | kernel 7.0.2-4 running, 7.0.14-17 installed, up 129 d | `proxmox_prep` runs `apt dist-upgrade` only when its paths change — not run in any of the last 40 deploys | 76 pending pkgs incl. security (curl, expat, xz, apt, bind9, nss, pcre2); never rebooted into new kernel; `pve-test` repo still enabled (docs/2026-05-26 says remove); no unattended-upgrades |
| Proxmox backups | vzdump job `sun 01:00`, `all`, storage `local_backups` | — | **storage does not exist → every run fails; zero backups of any guest.** `local` has 88 GB free; no NFS backup target; no notification target |
| TrueNAS VM 101 | version unverified (installed from 25.10-RC.1 ISO) | manual UI | boot disk not backed up; no TrueNAS config export; PVE-level `protection: 0` (Pulumi `Protect` only guards state) |
| Talos cluster (6 nodes) | Talos 1.14.1 (1.14.5 available), K8s 1.36.0, etcd healthy | Renovate bumps the pin; OS upgrade is manual `talosctl upgrade` (docs/2026-09-19) | pin PRs gated on dashboard approval even for patches; no etcd snapshots; no automation |
| Cluster PVCs (14, all `local-path`) | openbao raft ×3, arrs-pg ×3 (20 Gi), grafana, audiobookshelf ×2, readmebook ×2, victoria-metrics 40 Gi, victoria-logs 30 Gi | — | **no backups at all**; CNPG `backup: null`; no CSI snapshots; `openbao-2` sealed 46 d |
| Cluster apps (38 ArgoCD apps) | current to within days | Renovate daily 06:00 MT, automerge minor/patch for media/observability; platform charts PR-only | lscr.io lookups hit ghcr.io **429** (5 linuxserver images intermittently untracked); Renovate's own image pinned `43.231.4` and untracked (chart 46.375 ships newer); `node:22-alpine` untracked; platform-patch PRs (#424) and renovate/pulumi PRs (#410/#411) sit unmerged |
| Plex LXC 200 (Ubuntu 24.04.5) | Plex 1.43.5.11029 (.11079 avail) | `plex_server` role on path change only | 74 pending pkgs incl. security (glibc, curl, expat); `reboot-required` set; no unattended-upgrades; 27 GB Plex config not backed up |
| Tailscale LXC 100 (Ubuntu 24.04.4) | tailscale 1.94.2 | **none — not in IaC** (community script) | 150 pending pkgs; no unattended-upgrades |
| HAOS VM 250 | OS 18.2 (18.4 avail), Core 2026.8.0 (2026.11.0 avail), Z-Wave JS 1.6.0 (1.10.0 avail) | manual; Supervisor auto-updates itself | HA automatic backups run daily (verified) but stay on the VM disk, which is not backed up; `haos_image_filename` is hard-pinned to 17.3 while `haos_version` is 18.2 → next Stage 1 run 404s |
| Oracle Valheim (OCI A1, Ubuntu 24.04) | unverified live (SSH key use blocked in this session) | unattended-upgrades (security only), no auto-reboot; Valheim binary updates only when Ansible runs | world backups daily but **on the same disk only** (14 kept); Tailscale/box64 not auto-updated |
| GitHub Actions | 7 actions, major-tag pinned | Renovate automerge minor/patch | `renovate/pin-dependencies` (digest pinning) branch errors every run |

Renovate blind spots (not matched by any manager): ArgoCD bootstrap
`--version 9.5.11` in `deploy.yml` (gitops is on 10.10.5), `kubeconform
v0.6.7` + `yamllint 1.35.1` in `gitops.yml`, Terraform `oracle/oci ~> 9.0`
(terraform manager disabled), `depotdownloader_version`, Ubuntu LXC template
name, Renovate image tag, `node:22-alpine`.

CVE exposure for the running versions is in the companion report
`docs/2026-11-04-cve-audit.md` (written from the research pass).

## 3. Goals, non-goals, anti-goals

**Goals**
- Every data-bearing system has an automated, off-device backup that is
  test-restored on a schedule, with an alert when either stops happening.
- OS/package security patches apply automatically on every host, VM and LXC
  we control, with reboots in a defined window and health gates.
- Platform (Talos/K8s, platform charts, Renovate itself) patch releases flow
  without a human, minors still get a human merge, majors need approval.
- Failure of any step is visible in the existing alert path
  (vmalert → Home Assistant → Discord) or as a failed GitHub workflow.

**Non-goals**
- Automating TrueNAS SCALE *version* upgrades or Unifi (excluded).
- Zero-downtime for single-host events (there is one Proxmox host; a host
  reboot takes everything down for a few minutes — accepted, scheduled).
- Replacing Renovate/ArgoCD with another tool.

**Anti-goals (failure even if it "works")**
- A patch step that runs without a fresh, verified backup behind it.
- An automated action that can delete or overwrite TrueNAS data or the
  TrueNAS VM (`pulumi.Protect`, `protection: 1` must survive).
- Unseal keys or admin tokens ending up in the repo or in cluster manifests.

## 4. Constraints

- All changes via PRs; CI applies (`deploy.yml`) over Tailscale. No local
  `pulumi up` / `ansible-playbook` without `--check`.
- Talos is immutable; upgrades go through `talosctl upgrade` with the factory
  installer image (schematic `ce4c9805…`, qemu-guest-agent) one node at a
  time, control planes first.
- `local-path` PVs are node-local and have no CSI snapshot support.
- The Proxmox host has 88 GB free on `local`; TrueNAS has the only large
  storage. The GitHub runner cannot mount NFS.
- OpenBao seals on every pod restart; ExternalSecrets (15) stop syncing
  while it is sealed.

## 5. Design

### 5.1 Backups (foundation — ships first)

**Target:** a new TrueNAS dataset `Backups` with child datasets `proxmox`,
`k8s`, `homeassistant`, NFS-exported to `10.10.10.0/24` and
`192.168.1.0/24` (maproot=root like the media export). *Creating the dataset
+ export is a manual TrueNAS UI step (section 7).* ZFS snapshots on
`Backups` (daily, keep 30) are the second copy.

1. **Proxmox guests → two targets (owner direction, 2026-11-04).** The
   TrueNAS VM cannot be backed up to TrueNAS, and the host has a spare
   4 TB NVMe (`nvme1n1`, Crucial CT4000P310, LVM VG `nvme_4tb_front`, no
   LVs, 3.64 TB free). `proxmox_prep` carves LV `backups` (1 TB, ext4,
   mounted at `/mnt/nvme-backups`) and registers it as dir storage
   `nvme-backups` (content `backup`). Two declarative vzdump jobs
   (`pvesh create/set /cluster/backup`, idempotent):
   - `nightly-truenas`: VMID 101 → `nvme-backups`, 01:00,
     `keep-last=7,keep-weekly=4`.
   - `nightly-guests`: VMIDs 100, 200, 250 → `truenas-backups` (NFS from
     `192.168.1.40`, created when `proxmox_prep_backup_nfs_export` is set)
     with the same retention; until the export exists they go to
     `nvme-backups` too, so real backups start on the first merge with no
     manual prerequisite.
   Talos VMs are excluded (recreatable; their state is covered below). Both
   jobs use `mode snapshot`, `zstd`, `notification-mode
   notification-system`. A vzdump hook script writes
   `pve_backup_last_success_timestamp{vmid}` /
   `pve_backup_last_failure_timestamp{vmid}` to the node-exporter textfile
   dir so the existing `proxmox-host` scrape sees them.
2. **PVC backups → VolSync + restic.** Deploy `platform/volsync` (chart) and
   a `platform/restic-rest` (restic `rest-server`, single pod, its data on
   an NFS PV at `Backups/k8s/restic`). One `ReplicationSource` per PVC
   (copyMethod `Direct` — the mover pod is scheduled onto the PV's node by
   local-path's node affinity, so RWO is fine), hourly for openbao/grafana/
   audiobookshelf/readmebook, daily for victoria-metrics/logs, retention
   `hourly 24 / daily 14 / weekly 8`. The ReplicationSources live in a tiny
   wrapper chart `platform/pvc-backups` so adding a PVC is one list entry.
3. **Postgres (arrs-pg) → logical dumps.** CNPG CronJob `arrs-pg-dump` runs
   `pg_dumpall` with the superuser secret nightly 00:30 to the
   `Backups/k8s/postgres` NFS PV, keep 14. (Barman object-store backups
   need S3; `pg_dumpall` is sufficient for 20 Gi and restores anywhere.)
4. **OpenBao → raft snapshots.** CronJob `openbao-snapshot` hourly:
   `bao operator raft snapshot save` using a Kubernetes-auth role bound to a
   `snapshot` policy (`sys/storage/raft/snapshot` read), written to the
   `Backups/k8s/openbao` NFS PV, keep 48. Unseal keys are **not** needed to
   restore a snapshot into the same cluster.
5. **etcd → weekly `talosctl etcd snapshot`** from CI (talosconfig from the
   Pulumi stack output), copied to `pve1:/mnt/pve/truenas-backups/talos/`.
6. **Home Assistant → native automatic backups to network storage.** HA
   already makes a daily automatic backup; the only change is adding a
   network storage location (NFS `Backups/homeassistant`) in HA and
   selecting it as the backup target (UI step, section 7). The nightly
   vzdump of VM 250 is the crash-consistent fallback.
7. **Oracle Valheim → off-box copy.** Terraform adds an OCI Object Storage
   bucket `valheim-backups` (30-day lifecycle), a dynamic group for the
   instance and a policy allowing `manage objects` in that bucket; Ansible
   installs `rclone` configured with `provider = instance_principal` (no
   keys on disk) and `valheim-backup.sh` ends with
   `rclone sync /opt/valheim/backups oos:valheim-backups`.
8. **TrueNAS config.** The nightly vzdump of the 32 GB boot disk (VM 101)
   already captures the config database, so no separate export is
   required for "no data loss". Optional later: a weekly CronJob calling
   `POST /api/v2.0/config/save` (REST v2.0 is still served on the installed
   build — verified HTTP 401, not 404) with an *admin-scoped* key seeded
   separately from PR #309's read-only alert key.

**Restore drills (`restore-drill.yml`, monthly, manual dispatch too):**
- `qmrestore` the newest VM 250 archive to VMID 9250 and `pct restore` the
  newest 200 archive to 9200 on `local-lvm` (not started), assert the disks
  exist, destroy both; `zstd -t` the newest 101 and 100 archives. Archives
  are located by scanning every storage with `backup` content, so the drill
  does not care which target a guest currently uses.
- VolSync `ReplicationDestination` of the openbao and grafana repos into
  scratch PVCs; assert expected files; delete.
- Create a throwaway CNPG cluster `arrs-pg-drill` (1 instance, 5 Gi), load
  the newest dump, assert table counts for radarr/sonarr/prowlarr; delete.
- `rclone copy` the newest Valheim archive from the bucket; `tar -tzf`.
- `bao operator raft snapshot inspect` on the newest snapshot.
Any failing check fails the workflow and opens/updates a GitHub issue
labelled `backup-drill-failed`.

**Alerts (vmalert, existing path):** `BackupStaleProxmox`
(`time() - pve_backup_last_success_timestamp > 36h`), `BackupStaleCronJob`
(`kube_cronjob_status_last_successful_time` older than 2× schedule for the
backup CronJobs), `VolSyncOutOfSync` (`volsync_volume_out_of_sync == 1`),
`OpenBaoSealed` (`kube_pod_container_status_ready{namespace="openbao"} == 0`
for 15 m), `ExternalSecretNotReady` (ESO metric
`externalsecret_status_condition{condition="Ready",status="True"} == 0`
for 30 m — needs a VMServiceScrape for ESO), `KubeNodeNotReady`.

### 5.2 Patching rings

| Ring | What | Mechanism | Reboot | Gate / rollback |
|---|---|---|---|---|
| 0 Media + observability images/charts | existing | Renovate automerge minor/patch (unchanged) | n/a | ArgoCD health; revert PR |
| 1 Platform charts | argo-cd, cert-manager, traefik, metallb, ESO, CNPG, openbao, external-dns, metrics-server, local-path, **renovate chart** | **patch** updates automerge (new); minor stays Monday grouped PR; major needs approval | n/a | ArgoCD health + alerts; revert PR |
| 2 Talos / K8s | `talosVersion` patch: automerge; minor: PR, no approval; major: approval. `kubernetesVersion` patch: automerge; minor: approval (support matrix) | new deploy Stage 2c `talos-upgrade` (below) | rolling, 1 node at a time | per-node Ready + etcd + ArgoCD gate; auto `talosctl rollback` on timeout |
| 3 Ubuntu LXCs (Plex 200, Tailscale 100) | OS + Plex + Tailscale packages | unattended-upgrades (origins: Ubuntu security+updates, `o=Plex Media Server Repository`, `o=Tailscale`) plus `tailscale set --auto-update=true`; `Automatic-Reboot` 04:30 for Plex, 04:45 for Tailscale (a ~1 min loss of the CI subnet route at a time no workflow runs) | nightly if required | vzdump from the same night; `PlexDown` alert; the `plexmediaserver=1.43.5.11029` pin in `plex_server` (PR #404, a "bump to latest" not a hold) becomes `state: present` so Stage 3 can never downgrade |
| 4 Proxmox host | Debian security/updates + `o=Proxmox,c=pve-no-subscription` | unattended-upgrades for packages (no auto-reboot); `pve-test` repo removed (docs/2026-05-26); **the unconditional `apt dist-upgrade` task at the top of `proxmox_prep` is removed** so a Stage 1 run can never patch the host before a backup exists | **monthly maintenance window** workflow, first Sunday 03:00 MT | pre-flight: last night's vzdump succeeded for 100/101/200/250, cluster healthy; post: health check + OpenBao unseal |
| 5 Home Assistant | OS, Core, add-ons | HA automation `auto_update` package: when `update.home_assistant_core_update` / `…operating_system_update` / add-on update entities turn `on`, at 04:00 call `update.install` with `backup: true` (Core/add-ons) — OS update after a successful HA backup | HA-managed | HA pre-update backup + nightly vzdump; Supervisor can roll Core back |
| 6 Oracle Valheim | Ubuntu (security + updates + `o=Tailscale`), Valheim server binary | unattended-upgrades with `Automatic-Reboot` 10:15 UTC (after the 09:30 world backup); `valheim-update.timer` daily 10:00 UTC runs DepotDownloader, keeps `server.prev`, restarts only if the binary checksum changed | nightly if required | backup + off-box copy precede; `valheim-rollback.sh` swaps `server.prev` back |
| 7 TrueNAS SCALE | version upgrades | **manual** (runbook): config export + boot-disk vzdump are automated; TrueNAS "update available" surfaces as an alert via PR #309's alert-list exporter | manual | TrueNAS boot environments (built-in rollback) |
| 8 GitHub Actions | action versions | Renovate (unchanged) + fix digest pinning | n/a | CI |

**Stage 2c `talos-upgrade` (in `deploy.yml`)** runs when `pulumi-talos/main.go`
changed `talosVersion` or `kubernetesVersion` (detected by diffing the
constants against the previous commit; also `workflow_dispatch` inputs):
1. `talosctl etcd snapshot` (pre-flight).
2. For each control plane (.225, .228, .229) then worker (.226, .227, .232):
   `talosctl upgrade --image factory.talos.dev/installer/<schematic>:<ver>
   --preserve --wait --timeout 15m`; then wait for `kubectl get node` Ready,
   `talosctl etcd status` quorum, and ArgoCD apps `argocd`, `openbao`,
   `traefik` Healthy; on failure `talosctl rollback -n <node>` and stop.
3. If `kubernetesVersion` changed: `talosctl upgrade-k8s --to <ver>` (idempotent).
4. Runs **before** Stage 2b so Pulumi generates config for the version the
   nodes actually run. Upgrading first then applying config is the order the
   2026-09-19 incident established.
Secrets needed: talosconfig and kubeconfig come from Pulumi; `OPENBAO_UNSEAL_KEYS` only if the owner opts in (§8).

**Maintenance window (`maintenance-window.yml`, cron monthly + dispatch):**
1. Pre-flight: vzdump success timestamps for 100/101/200/250 < 30 h old,
   Talos nodes Ready, ArgoCD healthy, `reboot-required` or kernel mismatch
   actually present (otherwise exit 0 "nothing to do").
2. `apt-get dist-upgrade -y` (unattended-upgrades already keeps it current;
   this catches held/new packages), then `reboot` on `pve1`. Proxmox shuts
   guests down in reverse startup order itself.
3. Wait for `pve1`. **The CI runner reaches 192.168.1.0/24 only through
   the Tailscale LXC 100 subnet route (verified: it advertises
   `192.168.1.0/24`)**, so the reboot severs the runner's own path; the
   wait step polls `tailscale status` for the route + `ssh pve1` with a
   30-minute ceiling, and LXC 100 keeps `onboot: 1` with the lowest
   startup order (documented, since its definition stays manual). Then
   wait for guests `running`, Talos nodes Ready, TrueNAS NFS exports
   answering, Plex `/identity`, HA `/api/`.
4. OpenBao: if any replica is sealed, unseal using `OPENBAO_UNSEAL_KEYS`
   (GitHub Actions secret, 3 of 5 shares) — **owner decision, see §8**; if
   the secret is absent, skip and let `OpenBaoSealed` alert.
5. Post: `health-check.yml` (reusable) must pass; failure opens an issue
   labelled `maintenance-failed`.

### 5.3 Renovate coverage fixes

- ghcr.io 429: add a `hostRules` entry for `ghcr.io` using the minted App
  token (App needs `packages: read`), which also authenticates lscr.io
  redirects.
- Drop the explicit Renovate image `tag`; the chart's `appVersion` drives
  it. Add `renovate` chart to the platform-patch automerge rule.
- Pin `node:22-alpine` → exact `node:22.x.y-alpine` and add a single-line
  `image: repo:tag` regex (reuse the CNPG pattern, widened to
  `gitops/apps/**/values.yaml`).
- Regex managers for: ArgoCD bootstrap `--version` (datasource `helm`,
  registry argoproj), `kubeconform` and `yamllint` versions in `gitops.yml`,
  `depotdownloader_version` (github-releases `SteamRE/DepotDownloader`),
  LXC template name (not auto-bumpable — tracked for visibility only).
- Enable the `terraform` manager for `oracle-cloud-server/terraform/`.
- HAOS: derive `haos_image_filename` from `haos_version` and use get_url's
  `checksum: sha256:<url>.sha256` so a version bump is a one-line change.
- Talos/K8s approval rules per the ring table.
- Investigate `renovate/pin-dependencies` failure (likely the App lacks
  `workflows: write`); fix the permission or disable digest pinning for
  `.github/workflows` explicitly so the dashboard stops reporting an error.

### 5.4 Bringing the Tailscale LXC under IaC

New Ansible role `lxc_baseline` (unattended-upgrades config, auto-reboot
time, node-exporter textfile for `apt_upgrades_pending`/`reboot_required`)
applied to both LXCs. Plex LXC keeps SSH; the Tailscale LXC uses the
`community.general.proxmox_pct_remote` connection (pct exec via `pve1`),
so no SSH key is added to it. The container definition itself stays
manual (it is `protection: 1`), documented in `docs/`.

## 6. Rollout (PR series, each independently mergeable)

1. **PR 1 — Proxmox backups + drills.** vzdump fix (local fallback now,
   NFS when the dataset exists), hook metrics, `BackupStale*` alerts,
   `restore-drill.yml` (Proxmox part), remove `pve-test`, **remove the
   `apt dist-upgrade` task, and fix the HAOS image filename/checksum** (the
   current `haos_ova-17.3` pin would 404 and fail Stage 1 before the
   backup tasks run). Drill restores go to `local-lvm` (thin, 1.24 TB
   free of 1.76 TB — verified), one guest at a time.
2. **PR 2 — Cluster backups.** VolSync + restic rest-server + pvc-backups
   chart, arrs-pg dump CronJob, OpenBao snapshot CronJob + policy, ESO
   scrape + `OpenBaoSealed`/`ExternalSecretNotReady`/`KubeNodeNotReady`
   rules, drill steps.
3. **PR 3 — OS patching.** `lxc_baseline` role on both LXCs, host
   unattended-upgrades, `maintenance-window.yml` + `health-check.yml`,
   Oracle auto-reboot + Valheim update timer + rollback script + rclone
   offsite (Terraform bucket/IAM).
4. **PR 4 — Platform patch flow.** Renovate coverage fixes, ring policy,
   HAOS filename fix, Stage 2c Talos upgrade, etcd snapshot job.
5. **PR 5 — Home Assistant auto-update package** (`homeassistant/packages/
   auto_update.yaml`) + deploy note; TrueNAS runbook (+ optional config
   export CronJob); merge/finish #309.

First-run sequencing after merge: PR 1 → verify a vzdump succeeded → PR 3
→ first maintenance window (reboots `pve1` into kernel 7.0.14, applies the
76 + 74 + 150 pending packages) → PR 2/4/5 in any order → approve the
Talos 1.14.5 dashboard entry to exercise Stage 2c.

## 7. Manual prerequisites (owner)

1. TrueNAS: create dataset `Backups` (+ `proxmox`, `k8s`, `homeassistant`),
   NFS export to `10.10.10.0/24,192.168.1.0/24` with maproot root; enable a
   daily snapshot task on it (keep 30). Then set
   `proxmox_prep_backup_nfs_export` in `ansible/roles/proxmox_prep/defaults/main.yml`
   to move the non-TrueNAS guests off the NVMe. (Not a prerequisite any
   more: PR 1 backs everything up to the NVMe until then.)
2. Home Assistant: Settings → System → Storage → add network storage
   `backups` (NFS, `192.168.1.40:/mnt/<pool>/Backups/homeassistant` — the HAOS VM only has a vmbr0 NIC), then
   Settings → System → Backups → change location to it.
3. GitHub App `chalupa-renovate`: add `packages: read`; confirm
   `workflows: write`.
4. Decide on OpenBao unsealing (§8). Either way, **unseal `openbao-2` now**
   (`scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json`):
   with it sealed the PDB allows zero disruptions, so any node drain —
   automated or manual — blocks today.
5. OCI: confirm the Terraform user may create dynamic groups/policies.
6. Oracle box: the session could not SSH in; verify
   `unattended-upgrades` is active there before relying on ring 6.

## 8. Decisions and open questions

**Made (my calls, say if wrong):** Talos VMs excluded from vzdump;
platform-chart *patch* automerge; Proxmox reboots monthly not nightly;
LXC reboots nightly at 04:30; `pg_dumpall` instead of Barman; VolSync +
restic rest-server on NFS instead of Velero/MinIO; HA updates via an HA
automation rather than Supervisor API from CI; TrueNAS upgrades stay
manual; Valheim server auto-updates daily (mods may lag — same risk as
today, now with a rollback script).

**Owner must decide:**
1. OpenBao unsealing, which gates both ring 2 and ring 4 running unattended.
   Options, in my order of preference: (a) **auto-unseal with OCI KMS**
   (`seal "ocikms"`; OCI Vault is in the always-free tier; one-time seal
   migration; no keys anywhere in CI) — the durable fix; (b) store 3 of 5
   unseal shares as the GitHub Actions secret `OPENBAO_UNSEAL_KEYS` used
   only by the two workflows; (c) neither — then Talos node upgrades and
   host reboots stay PR-triggered and a human unseals afterwards, and the
   automation only alerts. (a) is a small extra PR; (b) ships in PR 3/4.
2. The TrueNAS pool name for the `Backups` dataset.
3. Whether the Pi K3s cluster (`chalupa-infra`) still exists anywhere.

**Resolved after the builder check (2026-11-04):** NFS mounts use
192.168.1.40 (pve1 has no vmbr1 IP, HAOS has only vmbr0); `local-lvm`
has room for the drills; TrueNAS REST v2.0 is still served; the Plex
version pin is dropped; `proxmox_prep` no longer dist-upgrades; the HAOS
filename fix moves into PR 1; LXC 100 is the CI subnet router and the
maintenance workflow is written around losing it.

## 9. Left to the builder

Exact chart versions, CronJob resource limits, VolSync schedule strings,
Ansible task shapes, the regex strings for the new Renovate managers, and
workflow step details. The builder must keep `pulumi.Protect(true)` on
TrueNAS and HAOS, must not add `--force` anywhere near `pct`/`qm destroy`
except on the drill VMIDs 9200/9250, and must make every drill/maintenance
job fail loudly rather than skip silently.
