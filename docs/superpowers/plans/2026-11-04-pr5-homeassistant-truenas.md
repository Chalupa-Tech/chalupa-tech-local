# PR 5 — Home Assistant auto-update + TrueNAS runbook — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Home Assistant OS, Core and add-ons update themselves at 04:00 behind an HA backup, and TrueNAS version upgrades have a written, backup-gated runbook with the "update available" signal surfaced as an alert.

**Architecture:** One HA package `homeassistant/packages/auto_update.yaml` (synced to `/config/packages/` by the documented SSH method) with: a time-triggered automation (04:00) that, for each `update.*` entity in the `on` state from an allow-list (`update.home_assistant_core_update`, `update.home_assistant_operating_system_update`, add-on update entities), calls `update.install` with `backup: true` for Supervisor-backed entities (Core/add-ons) and, for OS, only after `sensor.backup_last_successful_automatic_backup` is younger than 26 h; a notification to `notify.homeassistant_tejon_frame` on start and on failure; `input_boolean.auto_update_enabled` as the kill switch. Z-Wave JS add-on included (1.6 → 1.10 pending). TrueNAS: `docs/runbooks/truenas-upgrade.md` with the gate (nightly vzdump of 101 fresh + config export via UI/API) and PR #309's alert rules extended with `TrueNASUpdateAvailable` (TrueNAS raises an alert class `UpdateAvailable`/`HasUpdate` — confirm the `klass` label from the live alert list once #309 is in).

**Tech Stack:** Home Assistant automations YAML (packages), HA REST API for verification, Markdown runbook, VMRule (if #309 merged).

**Spec:** §5.2 rings 5, 7; §5.1 item 6; §6 PR 5; §7 item 2.

## Global Constraints
- Deploy method is the SSH pipe documented in `homeassistant/CLAUDE.md`; nothing here applies automatically — the docs entry says so and the PR body lists the two commands.
- Never call `update.install` for OS when `sensor.backup_last_successful_automatic_backup` is older than 26 h (HA backups run daily ~11:04 UTC; verified).
- Allow-list only; `update.uptime_card_update` etc. (HACS frontend) excluded — HACS updates are not Supervisor-backed and `backup: true` is rejected.
- The HA LLAT in `~/.config/ha/llat` is for *verification reads* only in this plan (reading `update.*`/automation states); it must not be committed or copied.

## Review Focus
1. `update.install` with `backup: true` on an entity that does not support backups raises an error and aborts the automation — the allow-list split (Core/add-ons with backup, OS without) must be exact (Task 1 test: `python3 -c` YAML load + assert each `service: update.install` call's target list and `backup` flag per group).
2. The automation must not run while another update is in progress (`sensor.backup_backup_manager_state != idle` or any allow-listed entity `in_progress: true`) — condition block, asserted by the same test.
3. Kill switch default `on`? No: `input_boolean.auto_update_enabled` initial `true` is what the owner asked for ("auto patching"); the docs entry tells them where to turn it off.
4. Runbook ordering for TrueNAS: config export → confirm 101 vzdump < 30 h → apply update → verify NFS exports from pve1 (`showmount -e`) and the media PVC still mounts (`kubectl -n media get pvc media-plexmedia`). No test; documentation.
5. After-run verification is read-only via REST: `curl … /api/states/automation.auto_update_nightly` exists and `last_triggered` populated after the first night.

---
### Task 1: `homeassistant/packages/auto_update.yaml` + YAML test
- Create the package (automation `auto_update_nightly`, `input_boolean.auto_update_enabled`, script `auto_update_notify`), `homeassistant/tests/test_auto_update_package.py` (pytest: loads YAML, asserts allow-lists, `backup: true` only on Core/add-on group, OS group guarded by the backup-age template condition, trigger `at: "04:00:00"`).
- Steps: write test → `pytest homeassistant/tests/test_auto_update_package.py` FAIL → write package → PASS → `yamllint homeassistant/packages/` → commit `feat(homeassistant): nightly auto-update automation with pre-update backups`.

### Task 2: TrueNAS runbook + alert hook
- Create `docs/runbooks/truenas-upgrade.md`; if PR #309 is merged by then add `TrueNASUpdateAvailable` to `gitops/apps/observability/vmalert/templates/rules/truenas.yaml` (`truenas_alert_active{klass=~".*Update.*"} > 0`, info, no `for`), else note it as a follow-up in the runbook.
- Commit `docs: TrueNAS upgrade runbook (manual, backup-gated)`.

### Task 3: Docs + PR
- `docs/2026-11-04-homeassistant-auto-update.md` (deploy commands, kill switch, what gets updated, verification), `homeassistant/README.md` pointer. PR `feat: Home Assistant auto-update + TrueNAS runbook (PR 5/5)` stacked on PR 4.
