# PR 1 — Proxmox backups + restore drill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every non-Talos guest on `pve1` (VMIDs 100, 101, 200, 250) get a nightly vzdump that is observable, alerted on, and test-restored monthly — and make Stage 1 unable to patch the host before that backup exists.

**Architecture:** `proxmox_prep` (already the owner of host state) gains a `backups.yml` task file that declares the NFS backup storage (optional until the TrueNAS dataset exists), replaces the broken vzdump job with a declarative one via `pvesh`, and installs a vzdump hook that writes per-VMID success/failure timestamps into node-exporter's textfile dir (already scraped as job `proxmox-host`). A VMRule file turns those into alerts. A monthly GitHub workflow restores the newest HAOS and Plex archives to scratch VMIDs 9250/9200 on `pve1`, verifies, destroys, and writes a drill timestamp. The unconditional `apt dist-upgrade` and the `pve-test` repo leave `proxmox_prep`; the HAOS image filename derives from `haos_version`.

**Tech Stack:** Ansible (`ansible.builtin.*`, host `pve1` as root), Proxmox CLI (`pvesh`, `pvesm`, `qmrestore`, `pct restore`, `vzdump` hook), bash + shellcheck, VictoriaMetrics `VMRule`, GitHub Actions (`.github/actions/connect-proxmox`).

**Spec:** `docs/superpowers/specs/2026-11-04-auto-patching-design.md` §5.1 items 1 and "Restore drills", §5.2 ring 4 (dist-upgrade removal), §6 PR 1, §7 item 1.

## Global Constraints

- All changes via PR; CI applies. Local `ansible-playbook … --check --diff` is allowed and is the integration test here (read-only against `pve1`).
- Never touch VMIDs other than the drill scratch IDs **9250** and **9200**; `qm destroy`/`pct destroy` may only ever receive those two.
- `pulumi.Protect(true)` on TrueNAS/HAOS and `protection: 1` on LXC 100 are untouched (nothing in this PR edits Pulumi or `pct set`).
- **Amended 2026-11-04 (owner):** two jobs. `nightly-truenas`: VMID `101` → dir storage `nvme-backups` (LV `backups`, 1T, ext4, VG `nvme_4tb_front`, mount `/mnt/nvme-backups`). `nightly-guests`: VMIDs `100,200,250` → `truenas-backups` NFS when `proxmox_prep_backup_nfs_export` is set, else `nvme-backups`. Both: schedule `01:00`, `mode snapshot`, `compress zstd`, `notification-mode notification-system`, notes `{{guestname}}`, retention `keep-last=7,keep-weekly=4`.
- NFS storage name `truenas-backups`, server `192.168.1.40`, content `backup`, created only when `proxmox_prep_backup_nfs_export` is non-empty.
- Textfile metrics live in `/var/lib/prometheus/node-exporter/` (verified present; `apt.prom` already there). Files must be written atomically (write temp, `mv`).
- Stage 1 path filter already matches `ansible/roles/proxmox_prep/**` and `ansible/group_vars/**`; no `deploy.yml` change needed for Ansible. The new workflow is a separate file.
- HAOS: `haos_image_filename: "haos_ova-{{ haos_version }}.qcow2.xz"`, checksum from the release `SHA256SUMS` asset (verified to exist for 18.4; multi-file format `<sha256>  <filename>` which `get_url` resolves by filename).

## Review Focus

1. Hook script invoked for a phase it does not handle (e.g. `log-end`, `pre-stop`) must exit 0 silently — vzdump aborts the backup if the hook exits non-zero. (Task 3 test `phase_ignored`.)
2. Existing job present with `storage: local` when the var flips to `truenas-backups`: the ensure script must `set` every managed field, not only create-if-missing. (Task 4 test `updates_drifted_job`.)
3. Drill with no archive for a VMID must fail the workflow, not pass vacuously. (Task 7 test `fails_when_no_archive`.)
4. Drill failure mid-way must still destroy 9250/9200 (trap), and must refuse to start if either already exists. (Task 7 tests `refuses_existing_scratch`, `cleans_up_on_failure`.)
5. `pvesh set` on a job with an unchanged `vmid` list given in a different order must be a no-op (compare as sorted sets). (Task 4 test `vmid_order_is_noop`.)

---

### Task 1: Stage 1 safety — drop host dist-upgrade, remove `pve-test` repo

**Files:**
- Modify: `ansible/roles/proxmox_prep/tasks/main.yml:1-5` (delete the "Ensure Proxmox system is up to date" task)
- Create: `ansible/roles/proxmox_prep/tasks/repos.yml`
- Modify: `ansible/roles/proxmox_prep/tasks/main.yml` (add `- ansible.builtin.import_tasks: repos.yml` as the first task)
- Modify: `ansible/roles/proxmox_prep/defaults/main.yml` (add `proxmox_prep_remove_pve_test_repo: true`)

**Interfaces:**
- Produces: nothing other tasks consume; Stage 1 no longer runs `apt upgrade`.

- [ ] **Step 1: Delete the dist-upgrade task** (lines 1-5 of `tasks/main.yml`, keep the leading comment).
- [ ] **Step 2: Write `tasks/repos.yml`** with two tasks: `ansible.builtin.file` `path: /etc/apt/sources.list.d/pve-test.list state: absent` registered as `proxmox_prep_pve_test_removed`, `when: proxmox_prep_remove_pve_test_repo`; then `ansible.builtin.apt: update_cache: true` `when: proxmox_prep_pve_test_removed is changed`. Comment: links `docs/2026-05-26-remove-kernel7-optin.md` (kernel 7 is PVE 9.2 default; pve-test mixes unreleased packages into a production host).
- [ ] **Step 3: Import it** at the top of `tasks/main.yml`.
- [ ] **Step 4: Lint.** Run: `cd ansible && ansible-lint` Expected: `Passed: 0 failure(s), 0 warning(s)`.
- [ ] **Step 5: Check mode against pve1.** Run: `cd ansible && ansible-playbook -i inventory.yml site.yml --check --diff --private-key ~/.ssh/pulumi_proxmox_runner 2>&1 | tee /tmp/claude-501/-Users-tbigelow/*/scratchpad/check1.txt | grep -E 'pve-test|changed=|failed='` Expected: the `pve-test.list` task shows `changed` with a `-` diff; `failed=0`; **no** task named "Ensure Proxmox system is up to date".
- [ ] **Step 6: Commit** `git add ansible && git commit -m "fix(proxmox_prep): stop dist-upgrading the host in Stage 1; drop pve-test repo"`.

### Task 2: HAOS image filename + checksum derived from `haos_version`

**Files:**
- Modify: `ansible/group_vars/all.yml` (replace `haos_image_filename` / `haos_image_sha256` lines)
- Modify: `ansible/roles/proxmox_prep/tasks/main.yml` (HAOS `get_url` task `checksum:`)

**Interfaces:**
- Produces: `haos_image_filename` = `haos_ova-{{ haos_version }}.qcow2.xz`; `haos_image_checksum` = `sha256:https://github.com/home-assistant/operating-system/releases/download/{{ haos_version }}/SHA256SUMS`.

- [ ] **Step 1: Verify the asset format.** Run: `curl -sL https://github.com/home-assistant/operating-system/releases/download/18.2/SHA256SUMS | grep qcow2` Expected: one line `<64 hex>  haos_ova-18.2.qcow2.xz`.
- [ ] **Step 2: Edit `group_vars/all.yml`:** delete `haos_image_sha256`, set `haos_image_filename` and add `haos_image_checksum` per Interfaces. Comment: Renovate bumps `haos_version` (regex manager in `renovate.json`); the filename must follow it or Stage 1 404s (it did at 17.3→18.2).
- [ ] **Step 3: Edit the `get_url` task** to `checksum: "{{ haos_image_checksum }}"`.
- [ ] **Step 4: Lint + check mode** (same commands as Task 1 steps 4-5). Expected: HAOS download task reports `changed` (file `haos_ova-18.2.qcow2.xz` absent on host), `failed=0`.
- [ ] **Step 5: Commit** `fix(proxmox_prep): derive HAOS image filename and checksum from haos_version`.

### Task 3: vzdump metrics hook script

**Files:**
- Create: `ansible/roles/proxmox_prep/files/vzdump-metrics-hook.sh`
- Create: `ansible/roles/proxmox_prep/files/tests/test_vzdump_hook.sh`

**Interfaces:**
- Invoked by vzdump as `vzdump-metrics-hook.sh <phase> [<mode> <vmid>]` with env `TARGET`, `STOREID` (per `/usr/share/doc/pve-manager/examples/vzdump-hook-script.pl`).
- Env override for tests: `VZDUMP_METRICS_FILE` (default `/var/lib/prometheus/node-exporter/vzdump.prom`).
- Produces metrics (one line per VMID, other VMIDs preserved):
  `pve_backup_last_success_timestamp{vmid="250",storage="local"} 1762250400`
  `pve_backup_last_failure_timestamp{vmid="250",storage="local"} 1762250400`
  plus `# HELP`/`# TYPE` headers once each.

- [ ] **Step 1: Write the failing test** `tests/test_vzdump_hook.sh` (bash, uses a temp dir, `set -euo pipefail`), with functions:
  - `records_success`: run `… backup-end snapshot 250` with `STOREID=local`; assert file contains `pve_backup_last_success_timestamp{vmid="250",storage="local"} <int>` and the int is within 5 s of `date +%s`.
  - `records_failure`: run `backup-abort snapshot 200`; assert a `pve_backup_last_failure_timestamp{vmid="200"…}` line exists and no success line for 200.
  - `preserves_other_vmids`: success for 250 then success for 200; assert both lines present, exactly one line per (metric, vmid).
  - `overwrites_same_vmid`: two successes for 250; assert exactly one success line for 250 with the later timestamp.
  - `phase_ignored`: run with `log-end`, `pre-stop`, `job-init`; assert exit 0 and file unchanged.
  - `atomic_write`: assert no `vzdump.prom.tmp*` left behind after any run.
  Each failure prints the function name and `exit 1`; end with `echo PASS`.
- [ ] **Step 2: Run it to see it fail.** Run: `bash ansible/roles/proxmox_prep/files/tests/test_vzdump_hook.sh` Expected: fails (script missing).
- [ ] **Step 3: Implement the hook** (bash, `set -euo pipefail`): handle `backup-end` → success, `backup-abort` → failure, everything else → `exit 0`. Read existing file (if any), drop lines matching the same metric+vmid, append the new line, write to `mktemp` in the same dir, `mv` over. Emit the two HELP/TYPE header pairs at the top on every write.
- [ ] **Step 4: Run test + shellcheck.** Run: `shellcheck ansible/roles/proxmox_prep/files/vzdump-metrics-hook.sh && bash ansible/roles/proxmox_prep/files/tests/test_vzdump_hook.sh` Expected: no shellcheck output; `PASS`.
- [ ] **Step 5: Commit** `feat(proxmox_prep): vzdump hook exporting per-VMID backup timestamps`.

### Task 4: Idempotent vzdump job manager

**Files:**
- Create: `ansible/roles/proxmox_prep/files/ensure-vzdump-job.sh`
- Create: `ansible/roles/proxmox_prep/files/tests/test_ensure_vzdump_job.sh`
- Create: `ansible/roles/proxmox_prep/files/tests/fixtures/` (JSON `pvesh get /cluster/backup` outputs: `none.json`, `legacy.json` (the live `backup-af8b79f5-6e9a` job), `current.json`, `drifted-storage.json`, `vmid-reordered.json`)

**Interfaces:**
- CLI: `ensure-vzdump-job.sh --id <jobid> --schedule <s> --vmids <csv> --storage <name> --prune <keep-spec> [--delete-id <legacy-id>]... [--check]`
- Shells out only to `pvesh` (`get /cluster/backup --output-format json`, `create /cluster/backup`, `set /cluster/backup/<id>`, `delete /cluster/backup/<id>`). Tests stub `pvesh` via a `PATH` shim that serves a fixture and logs calls to `$PVESH_LOG`.
- Prints exactly one of `CHANGED` / `UNCHANGED` on the last stdout line; exit 0. `--check` prints the verdict without calling `create/set/delete`.
- Fixed fields it always sets on create/set: `--mode snapshot --compress zstd --enabled 1 --notification-mode notification-system --notes-template '{{guestname}}'`.

- [ ] **Step 1: Write the failing test** with cases: `creates_when_absent` (fixture `none.json` → one `create` call containing `--id nightly-guests --schedule 01:00 --vmid 100,101,200,250 --storage local --prune-backups keep-last=1`; prints `CHANGED`), `deletes_legacy` (fixture `legacy.json` + `--delete-id backup-af8b79f5-6e9a` → `delete` call then `create`), `noop_when_current` (fixture `current.json` → no create/set/delete; `UNCHANGED`), `updates_drifted_job` (fixture `drifted-storage.json` where storage=local but requested `truenas-backups` → one `set` call with `--storage truenas-backups --prune-backups keep-last=7,keep-weekly=4`), `vmid_order_is_noop` (fixture `vmid-reordered.json` with `vmid: "250,100,200,101"` → `UNCHANGED`), `check_mode_mutates_nothing` (fixture `none.json` + `--check` → `CHANGED`, zero mutating calls).
- [ ] **Step 2: Run it to see it fail.** Expected: fails (script missing).
- [ ] **Step 3: Implement** in bash with `jq` (present on pve1, verified via `apt list`): parse args; `get` once; build desired object; compare `schedule`, sorted `vmid`, `storage`, `prune-backups` (string compare after normalising `keep-last=7,keep-weekly=4` ↔ object `{keep-last:"7",keep-weekly:"4"}`), `mode`, `compress`; delete legacy ids that exist; create or set; print verdict.
- [ ] **Step 4: Run test + shellcheck.** Expected: `PASS`, no shellcheck findings.
- [ ] **Step 5: Commit** `feat(proxmox_prep): idempotent vzdump job manager`.

### Task 5: `backups.yml` tasks + defaults

**Files:**
- Create: `ansible/roles/proxmox_prep/tasks/backups.yml`
- Modify: `ansible/roles/proxmox_prep/tasks/main.yml` (append `- ansible.builtin.import_tasks: backups.yml`)
- Modify: `ansible/roles/proxmox_prep/defaults/main.yml`

**Interfaces:**
- Defaults (exact names, amended): `proxmox_prep_backup_vg: nvme_4tb_front`, `proxmox_prep_backup_lv: backups`, `proxmox_prep_backup_lv_size: 1T`, `proxmox_prep_backup_mount: /mnt/nvme-backups`, `proxmox_prep_backup_schedule: "01:00"`, `proxmox_prep_backup_prune: keep-last=7,keep-weekly=4`, `proxmox_prep_backup_truenas_vmids: [101]`, `proxmox_prep_backup_guest_vmids: [100, 200, 250]`, `proxmox_prep_backup_nfs_server: "192.168.1.40"`, `proxmox_prep_backup_nfs_export: ""`, `proxmox_prep_backup_guest_storage: "{{ 'truenas-backups' if proxmox_prep_backup_nfs_export else 'nvme-backups' }}"`, `proxmox_prep_backup_legacy_job_ids: [backup-af8b79f5-6e9a]`.
- Installs: `/usr/local/bin/vzdump-metrics-hook.sh` (0755), `/usr/local/bin/ensure-vzdump-job.sh` (0755), `script: /usr/local/bin/vzdump-metrics-hook.sh` line in `/etc/vzdump.conf` (`lineinfile`, `regexp: '^script:'`).

- [ ] **Step 1: Write the defaults** per Interfaces with a comment block explaining the local→NFS switch and the one-line owner action.
- [ ] **Step 2: Write `backups.yml`:** (a) `ansible.builtin.command: pvesm status` registered, `changed_when: false`, `check_mode: false`; (b) `pvesm add nfs truenas-backups --server … --export … --content backup --options vers=4.2` `when: proxmox_prep_backup_nfs_export and 'truenas-backups' not in status.stdout`; (c) copy the two scripts; (d) vzdump.conf `lineinfile`; (e) run `ensure-vzdump-job.sh` with `--check` appended when `ansible_check_mode`, `check_mode: false`, `changed_when: "'CHANGED' in ensure.stdout_lines[-1]"`, passing `--delete-id` per legacy id.
- [ ] **Step 3: Lint.** `ansible-lint` Expected: clean.
- [ ] **Step 4: Check mode against pve1.** Expected output includes: `pvesm add` task skipped (export empty), scripts `changed`, vzdump.conf `changed`, ensure-job task `changed` and its stdout shows `CHANGED` only; `failed=0`.
- [ ] **Step 5: Commit** `feat(proxmox_prep): declarative nightly vzdump job, NFS target, metrics hook`.

### Task 6: Backup alert rules

**Files:**
- Create: `gitops/apps/observability/vmalert/templates/rules/backups.yaml`

**Interfaces:**
- VMRule `backups` in `vm-system`, group `backups`, rules:
  - `ProxmoxBackupStale`: `time() - max by (vmid) (pve_backup_last_success_timestamp{job="proxmox-host"}) > 36*3600`, for 30m, warning.
  - `ProxmoxBackupFailed`: `pve_backup_last_failure_timestamp{job="proxmox-host"} > ignoring(storage) pve_backup_last_success_timestamp{job="proxmox-host"}`, for 10m, critical.
  - `ProxmoxBackupMetricsAbsent`: `absent(pve_backup_last_success_timestamp{job="proxmox-host"})`, for 2h, warning (fires until the first successful run — intended).
  - `ProxmoxRestoreDrillStale`: `time() - pve_restore_drill_last_success_timestamp{job="proxmox-host"} > 40*86400 or absent(pve_restore_drill_last_success_timestamp{job="proxmox-host"})`, for 1h, warning.
  - `ProxmoxRebootRequired`: `node_reboot_required{job="proxmox-host"} > 0`, for 14d, warning (metric already produced by the apt textfile collector).

- [ ] **Step 1: Write the file** following `rules/proxmox-host.yaml` (same apiVersion, namespace, sync-wave annotation, summary/description style).
- [ ] **Step 2: Render + validate like CI.** Run: `yamllint gitops/ && helm template vmalert gitops/apps/observability/vmalert --api-versions monitoring.coreos.com/v1 | kubeconform -strict -ignore-missing-schemas -summary -skip VMRule,VMAlert,VMAlertmanager -schema-location default` Expected: `Valid: N, Invalid: 0, Errors: 0`.
- [ ] **Step 3: Commit** `feat(vmalert): backup freshness, failure, drill and reboot-required alerts`.

### Task 7: Restore drill script

**Files:**
- Create: `scripts/proxmox/restore-drill.sh`
- Create: `scripts/proxmox/tests/test_restore_drill.sh`

**Interfaces:**
- Runs **on pve1** as root. CLI: `restore-drill.sh --storage <backup-storage> [--vm 250:9250] [--ct 200:9200] [--verify-only 101,100]`. Defaults: those exact pairs and verify list.
- For each `--vm src:scratch`: refuse if `qm status <scratch>` succeeds; newest archive = union of `pvesm list <s> --vmid <src> --content backup` over all backup storages, sorted by the timestamp in the volid, last; `qmrestore <volid> <scratch> --storage local-lvm --unique 1`; assert `qm config <scratch>` has `scsi0`; `qm destroy <scratch> --purge 1` (also in an `EXIT` trap). `--ct` identical with `pct status`/`pct restore <scratch> <volid> --storage local-lvm --unique 1`/`pct config` has `rootfs`/`pct destroy <scratch> --purge 1`.
- For `--verify-only` VMIDs: newest archive must exist and `zstd -t <path>` passes (path from `pvesm path <volid>`).
- Writes `pve_restore_drill_last_success_timestamp <now>` to `/var/lib/prometheus/node-exporter/restore-drill.prom` (atomic) only when every step passed. Exit non-zero on any failure, with a one-line reason per failure.
- Tests stub `qm`, `pct`, `qmrestore`, `pvesm`, `zstd` via PATH shims logging to `$DRILL_LOG`; override the prom path via `DRILL_METRICS_FILE`.

- [ ] **Step 1: Write the failing test** with cases: `restores_newest_and_destroys` (two archives for 250 → qmrestore called with the newer volid, then `qm destroy 9250 --purge 1`), `fails_when_no_archive` (empty list → non-zero exit, no prom file), `refuses_existing_scratch` (`qm status 9250` stub returns 0 → non-zero exit before any restore call), `cleans_up_on_failure` (`qm config` stub returns no `scsi0` → non-zero exit AND `qm destroy 9250` still called once), `verify_only_runs_zstd` (`zstd -t` called with the newest 101 archive path), `writes_metric_on_success`.
- [ ] **Step 2: Run it to see it fail.**
- [ ] **Step 3: Implement** per Interfaces (bash, `set -euo pipefail`, trap-based cleanup that is safe to run twice).
- [ ] **Step 4: Run test + shellcheck.** Expected: `PASS`, clean.
- [ ] **Step 5: Commit** `feat(proxmox): restore-drill script (qmrestore/pct restore to scratch VMIDs, verify, destroy)`.

### Task 8: Restore drill workflow

**Files:**
- Create: `.github/workflows/restore-drill.yml`

**Interfaces:**
- `on: schedule: - cron: '0 10 1 * *'` (03:00 America/Denver on the 1st, UTC-7; note the DST drift in a comment) + `workflow_dispatch` (no inputs; amended).
- Job `drill`: `actions/checkout@v7` → `./.github/actions/connect-proxmox` (same secrets as `deploy.yml`) → `scp scripts/proxmox/restore-drill.sh root@192.168.1.223:/usr/local/bin/` → `ssh root@192.168.1.223 restore-drill.sh` with `timeout-minutes: 60`.
- Job `report` (`if: failure()`, `permissions: issues: write`): `actions/github-script@v9` finds an open issue labelled `backup-drill-failed` titled `Restore drill failed`; creates it or appends a comment with the run URL.

- [ ] **Step 1: Write the workflow.**
- [ ] **Step 2: Validate.** Run: `yamllint .github/workflows/restore-drill.yml && (command -v actionlint && actionlint .github/workflows/restore-drill.yml || echo "actionlint not installed")` Expected: no errors.
- [ ] **Step 3: Commit** `ci: monthly Proxmox restore drill workflow`.

### Task 9: Docs + PR

**Files:**
- Create: `docs/2026-11-04-fix-proxmox-backups.md` (symptom: job pointed at non-existent `local_backups`, zero backups since March; what changed; the owner step to switch to NFS = set `proxmox_prep_backup_nfs_export`; how to read the metrics; PR link `#TBD`)
- Modify: `README.md` "Operational notes" — add "Backups" subsection (where archives are, how to run the drill by hand: `gh workflow run restore-drill.yml`).
- Modify: `CLAUDE.md` Critical Rules — add: "Drill scratch VMIDs 9250/9200 are the only VMIDs any automation may destroy".

- [ ] **Step 1: Write the three edits.**
- [ ] **Step 2: Full local verification.** Run: `cd ansible && ansible-lint && ansible-playbook -i inventory.yml site.yml --check --diff --private-key ~/.ssh/pulumi_proxmox_runner | tail -5; cd .. && yamllint gitops/ .github/workflows/restore-drill.yml && bash ansible/roles/proxmox_prep/files/tests/test_vzdump_hook.sh && bash ansible/roles/proxmox_prep/files/tests/test_ensure_vzdump_job.sh && bash scripts/proxmox/tests/test_restore_drill.sh` Expected: all `PASS`, play recap `failed=0`.
- [ ] **Step 3: Commit, push, open PR** titled `feat: working nightly Proxmox backups + monthly restore drill (PR 1/5 auto-patching)` with body summarising §2 findings, the `local` → NFS switch instructions, and "Stage 1 no longer dist-upgrades the host". Fill the PR number into the docs entry in a follow-up commit.
