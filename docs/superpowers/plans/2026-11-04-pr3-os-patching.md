# PR 3 — OS patching rings 3/4/6 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Debian/Ubuntu system we run (pve1, Plex LXC 200, Tailscale LXC 100, the Oracle Valheim VM) applies security and vendor patches automatically, reboots in a defined window behind a backup gate, and reports health afterwards — with the Tailscale LXC brought under Ansible and the Valheim world copied off-box.

**Architecture:** One shared Ansible role `unattended_upgrades` renders `/etc/apt/apt.conf.d/50unattended-upgrades` + `20auto-upgrades` from a list of apt origins and reboot settings; `proxmox_prep` imports it (Proxmox + Debian origins, no auto-reboot) and a new `lxc_baseline` role wraps it for the two LXCs (Ubuntu + Plex/Tailscale origins, nightly auto-reboot, `tailscale set --auto-update`). The Tailscale LXC joins `inventory-vms.yml` over the `community.proxmox.proxmox_pct_remote` connection (pct exec via pve1, no SSH key inside). A reusable `health-check.yml` workflow runs `scripts/health-check.sh` from the runner; `maintenance-window.yml` (monthly) runs `scripts/proxmox/maintenance-reboot.sh` on pve1 behind a backup-freshness pre-flight, survives losing the Tailscale subnet route while pve1 reboots, optionally unseals OpenBao, then calls the health check. The Oracle `base` role reuses the shared role (plus `Automatic-Reboot` after the 09:30 world backup), a `valheim-update.timer` pulls the Steam build daily with a rollback copy, and `valheim-backup.sh` syncs archives to an OCI bucket via rclone instance-principal auth (Terraform: bucket, dynamic group, policy).

**Tech Stack:** Ansible (`ansible.builtin.*`, `community.proxmox.proxmox_pct_remote`, paramiko), unattended-upgrades, systemd timers, bash + shellcheck, GitHub Actions (`workflow_call`, `.github/actions/connect-proxmox`), Terraform `oracle/oci`, rclone (`oracleobjectstorage` backend, `provider = instance_principal`).

**Spec:** `docs/superpowers/specs/2026-11-04-auto-patching-design.md` §5.2 rings 3, 4, 6; "Maintenance window"; §5.4; §5.1 item 7; §7 items 4, 5, 6; §8 decision 1.

## Global Constraints

- All changes via PR; CI applies. Local `--check --diff` allowed. Never run `ansible-playbook` without `--check` locally, never `pulumi up`.
- Apt origins (exact `Unattended-Upgrade::Origins-Pattern` entries): Debian: `origin=Debian,codename=${distro_codename}-security,label=Debian-Security` and `origin=Debian,codename=${distro_codename}-updates`; Proxmox: `origin=Proxmox,codename=${distro_codename},label=Proxmox Debian Repository`; Ubuntu: `origin=Ubuntu,codename=${distro_codename}-security,label=Ubuntu` and `origin=Ubuntu,codename=${distro_codename}-updates`; Plex: `origin=Plex Media Server Repository`; Tailscale: `origin=Tailscale`.
- Reboot times: Plex LXC `04:30`, Tailscale LXC `04:45`, Oracle `10:15` (UTC, after the 09:30 world backup timer). pve1: `Automatic-Reboot "false"`.
- Maintenance window cron: `0 10 1-7 * 0`… cron cannot express "first Sunday"; use `0 10 * * 0` (every Sunday 10:00 UTC = 03:00 MST) and let the pre-flight exit 0 "nothing to do" when neither `node_reboot_required > 0` nor a kernel mismatch (`uname -r` ≠ newest installed `proxmox-kernel-*`) is present. Backup gate: `pve_backup_last_success_timestamp` for each of 100, 101, 200, 250 younger than 30 h, read from `/var/lib/prometheus/node-exporter/vzdump.prom`.
- The CI runner reaches 192.168.1.0/24 only via the Tailscale LXC 100 subnet route (verified). The maintenance workflow's reconnect loop waits up to 30 minutes for `ssh root@192.168.1.223 true` to succeed again.
- OpenBao unseal in CI is opt-in: secret `OPENBAO_UNSEAL_KEYS` (newline-separated shares). Absent → skip with a notice. Keys are never echoed; use `kubectl exec openbao-N -- bao operator unseal <key>` with the key passed via stdin-free env, `set +x`.
- Plex: `plexmediaserver` installed with `state: present`, no version pin.
- Tailscale LXC 100: definition stays manual (`protection: 1`); only in-container config is managed. `tailscale set --auto-update=true` on both LXCs and the Oracle box.
- Oracle world backups: bucket name `valheim-backups`, lifecycle delete after 30 days; rclone remote name `oos`; sync command `rclone sync /opt/valheim/backups oos:valheim-backups --config /opt/valheim/rclone.conf`.
- Valheim updater: `/opt/valheim/valheim-update.sh` runs DepotDownloader into `{{ valheim_server_dir }}`; before download `rsync -a --delete server/ server.prev/`; restart `valheim.service` only if `sha256sum valheim_server.x86_64` changed; `valheim-rollback.sh` swaps `server.prev` back and restarts. Timer `valheim-update.timer` daily `10:00 UTC`.
- `.github/workflows/deploy.yml` Stage 3 generates `inventory-vms.yml` inline — it must gain the Tailscale LXC host (connection `community.proxmox.proxmox_pct_remote`, `ansible_host: 192.168.1.223`, `ansible_user: root`, `proxmox_vmid: 100`) and the step `pip install ansible paramiko` + `ansible-galaxy collection install ansible.posix community.general community.proxmox`.

## Review Focus

1. unattended-upgrades on pve1 must never reboot or remove packages: `Automatic-Reboot "false"`, `Remove-Unused-Dependencies "false"` on the host (Task 1 test `host_profile_has_no_autoreboot`).
2. Maintenance pre-flight with a *missing* vzdump.prom (fresh host) must refuse, not pass (Task 5 test `refuses_without_backup_metrics`).
3. health-check must fail on a sealed OpenBao replica even when every other check passes (Task 4 test `fails_on_sealed_openbao`).
4. Valheim updater when DepotDownloader fails mid-download must leave `server.prev` intact and not restart the service (Task 6 test `download_failure_keeps_prev_and_service`).
5. The Tailscale LXC reboot at 04:45 must not coincide with any scheduled workflow: restore-drill 10:00 UTC, maintenance 10:00 UTC Sundays, Renovate in-cluster 06:00 MT — documented in Task 7's docs entry; no test.

---

### Task 1: Shared `unattended_upgrades` role

**Files:**
- Create: `ansible/roles/unattended_upgrades/defaults/main.yml`, `tasks/main.yml`, `templates/50unattended-upgrades.j2`, `templates/20auto-upgrades.j2`
- Create: `ansible/roles/unattended_upgrades/tests/render.yml` + `tests/test_render.sh`

**Interfaces:**
- Vars: `unattended_upgrades_origins: []` (list of Origins-Pattern strings), `unattended_upgrades_auto_reboot: false`, `unattended_upgrades_reboot_time: "04:30"`, `unattended_upgrades_remove_unused: false`, `unattended_upgrades_mail: ""`.
- Tasks: `apt` install `unattended-upgrades` + `apt-listchanges` absent? (no — leave), template both files (0644), `systemd_service` `unattended-upgrades` enabled+started.
- Template output lines (exact): `Unattended-Upgrade::Automatic-Reboot "true|false";`, `Unattended-Upgrade::Automatic-Reboot-Time "HH:MM";`, `Unattended-Upgrade::Remove-Unused-Dependencies "…";`, one `"<origin>";` per origin inside `Unattended-Upgrade::Origins-Pattern { … };`. `20auto-upgrades`: `APT::Periodic::Update-Package-Lists "1";`, `APT::Periodic::Unattended-Upgrade "1";`, `APT::Periodic::AutocleanInterval "7";`.

- [ ] **Step 1: Write the failing render test.** `tests/render.yml`: play on `localhost` `connection: local` `gather_facts: false` that templates both files into `{{ out_dir }}` using `ansible.builtin.template` with `src: ../templates/...` for two profiles (vars files `profile_host.yml`: Debian+Proxmox origins, no reboot; `profile_lxc.yml`: Ubuntu+Plex+Tailscale origins, reboot 04:30). `tests/test_render.sh` runs `ansible-playbook tests/render.yml -e out_dir=$tmp -e @tests/profile_host.yml` then asserts: `host_profile_has_no_autoreboot` (`Automatic-Reboot "false"` present, `Remove-Unused-Dependencies "false"`), `host_profile_origins` (both Debian lines + the Proxmox line present, no Ubuntu line), `lxc_profile_reboots_at_time` (`Automatic-Reboot "true"`, `Automatic-Reboot-Time "04:30"`), `lxc_profile_origins` (Plex + Tailscale lines), `periodic_file` (the three APT::Periodic lines). Print `PASS`.
- [ ] **Step 2: Run it.** Expected: FAIL (templates missing).
- [ ] **Step 3: Write defaults, templates, tasks** per Interfaces.
- [ ] **Step 4: Run test + lint.** Run: `bash ansible/roles/unattended_upgrades/tests/test_render.sh && (cd ansible && ansible-lint)` Expected: `PASS`; lint clean.
- [ ] **Step 5: Commit** `feat(ansible): shared unattended_upgrades role`.

### Task 2: Proxmox host profile in `proxmox_prep`

**Files:**
- Modify: `ansible/roles/proxmox_prep/tasks/main.yml` (add `import_role: name: unattended_upgrades` after `repos.yml`, with `vars:` Debian security/updates + Proxmox origins, `unattended_upgrades_auto_reboot: false`)
- Modify: `ansible/roles/proxmox_prep/defaults/main.yml` (`proxmox_prep_unattended_origins` list per Global Constraints)

- [ ] **Step 1: Edit** per Files.
- [ ] **Step 2: Lint + check mode against pve1.** Expected: template tasks `changed` with diffs showing the three origins and `Automatic-Reboot "false"`; `failed=0`.
- [ ] **Step 3: Commit** `feat(proxmox_prep): unattended security upgrades on the host (no auto-reboot)`.

### Task 3: `lxc_baseline` role, Tailscale LXC in inventory, Plex pin dropped

**Files:**
- Create: `ansible/roles/lxc_baseline/defaults/main.yml`, `tasks/main.yml`
- Modify: `ansible/playbooks/vm-configure.yml` (Play 2 adds role `lxc_baseline` before `plex_server`; new Play 3 `Configure Tailscale LXC` hosts `tailscale_lxc`, `gather_facts: false` then explicit `setup`, roles `lxc_baseline`)
- Modify: `ansible/inventory-vms.yml` (add `tailscale_lxc: hosts: tailscale: ansible_host: 192.168.1.223, ansible_user: root, ansible_connection: community.proxmox.proxmox_pct_remote, proxmox_vmid: 100`)
- Modify: `.github/workflows/deploy.yml` Stage 3: inventory heredoc gains the same host; install step gains `paramiko` + `community.proxmox`
- Modify: `.github/workflows/ansible.yml` lint job: install `community.proxmox` so `ansible-lint` resolves the connection plugin
- Modify: `ansible/roles/plex_server/tasks/main.yml:171-177` → `name: plexmediaserver`, `state: present`

**Interfaces:**
- `lxc_baseline` vars: `lxc_baseline_origins` (Ubuntu security + updates by default), `lxc_baseline_extra_origins: []`, `lxc_baseline_reboot_time: "04:30"`, `lxc_baseline_tailscale_auto_update: false`. It `import_role`s `unattended_upgrades` with `unattended_upgrades_origins: "{{ lxc_baseline_origins + lxc_baseline_extra_origins }}"`, `unattended_upgrades_auto_reboot: true`. If `lxc_baseline_tailscale_auto_update`: `command: tailscale set --auto-update=true` with `changed_when: false` (idempotent flag).
- Plex host vars (in play): `lxc_baseline_extra_origins: ["origin=Plex Media Server Repository"]`, `lxc_baseline_reboot_time: "04:30"`, `lxc_baseline_tailscale_auto_update: false`. Tailscale host vars: `lxc_baseline_extra_origins: ["origin=Tailscale"]`, `lxc_baseline_reboot_time: "04:45"`, `lxc_baseline_tailscale_auto_update: true`.

- [ ] **Step 1: Write the role, playbook, inventory and workflow edits.**
- [ ] **Step 2: Lint + syntax + limited check.** Run: `cd ansible && ansible-lint && ansible-playbook -i inventory-vms.yml playbooks/vm-configure.yml --syntax-check && ansible-playbook -i inventory-vms.yml playbooks/vm-configure.yml --check --diff --limit tailscale --private-key ~/.ssh/pulumi_proxmox_runner` Expected: lint clean; syntax OK; the Tailscale play reaches the container via pct (facts gathered, `unattended-upgrades` install `changed`, template diffs show `origin=Tailscale`), `failed=0`. (The Plex play is not checked locally: the workstation's known_hosts entry for 192.168.1.224 is stale; CI's Stage 3 uses `accept-new`.)
- [ ] **Step 3: actionlint.** Run: `actionlint .github/workflows/deploy.yml .github/workflows/ansible.yml` Expected: clean.
- [ ] **Step 4: Commit** `feat(ansible): lxc_baseline (unattended-upgrades + nightly reboot) for Plex and Tailscale LXCs; drop Plex pin`.

### Task 4: `health-check.sh` + reusable `health-check.yml`

**Files:**
- Create: `scripts/health-check.sh`, `scripts/tests/test_health_check.sh`
- Create: `.github/workflows/health-check.yml` (`on: workflow_call` + `workflow_dispatch`; inputs none; secrets inherited via `secrets: inherit` from callers)

**Interfaces:**
- Runs on the runner (Tailscale up, ssh agent loaded, `KUBECONFIG` exported by the workflow from `pulumi stack output kubeconfig --show-secrets`). Env overrides for tests: `HC_PVE=192.168.1.223`, `HC_PLEX_URL=http://192.168.1.224:32400/identity`, `HC_HA_URL=http://192.168.1.234:8123/`, `HC_TRUENAS=192.168.1.40`, `HC_GUESTS="100 101 200 250"`.
- Checks, each printing `ok <name>` or `FAIL <name>: <reason>`; exit 1 if any FAIL: `pve-ssh` (`ssh root@$HC_PVE true`), `guests-running` (`qm list`/`pct list` on pve1 show every HC_GUESTS id `running`), `talos-nodes-ready` (`kubectl get nodes` all Ready, count 6), `argocd-healthy` (`kubectl -n argocd get applications -o json`: every app `.status.health.status == Healthy`), `openbao-unsealed` (each pod `openbao-0..2`: `kubectl -n openbao exec $pod -- bao status -format=json | jq .sealed == false`), `externalsecrets-ready` (no ExternalSecret with Ready != True), `plex-identity` (`curl -fsS $HC_PLEX_URL`), `ha-http` (`curl -fsS -o /dev/null $HC_HA_URL` accepting 200/30x/401), `truenas-nfs` (`ssh root@$HC_PVE showmount -e $HC_TRUENAS` lists `/mnt/PlexMedia/frame`).
- Tests stub `ssh`, `kubectl`, `curl`, `jq` is real; stub behaviour via env (`HC_STUB_SEALED=1` makes openbao-2 sealed, `HC_STUB_NODE_NOTREADY=1`, `HC_STUB_APP_DEGRADED=1`, `HC_STUB_GUEST_STOPPED=200`).

- [ ] **Step 1: Write the failing test** with cases `all_green_exits_zero`, `fails_on_sealed_openbao`, `fails_on_node_not_ready`, `fails_on_degraded_app`, `fails_on_stopped_guest`, `reports_every_check_even_after_failure` (all nine names appear in output when two fail).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** the script; then the workflow: checkout → `connect-proxmox` → Install Pulumi CLI + `pulumi stack output kubeconfig --show-secrets --stack tayvenb13/chalupa-talos/proxmox --cwd pulumi-talos/ > /tmp/kubeconfig` (same as deploy.yml Stage 4) → install kubectl → `bash scripts/health-check.sh`.
- [ ] **Step 4: Run test + shellcheck + actionlint.** Expected: `PASS`, clean.
- [ ] **Step 5: Commit** `ci: reusable health-check workflow + script`.

### Task 5: Maintenance window

**Files:**
- Create: `scripts/proxmox/maintenance-reboot.sh`, `scripts/proxmox/tests/test_maintenance_reboot.sh`
- Create: `scripts/openbao/unseal-ci.sh` (reads `OPENBAO_UNSEAL_KEYS`, unseals any sealed replica; `set +x`; never prints keys)
- Create: `.github/workflows/maintenance-window.yml`

**Interfaces:**
- `maintenance-reboot.sh [--check]` runs on pve1 as root. Exit codes: `0` rebooting (or `--check`: "would reboot"), `3` nothing to do, `1` pre-flight refused. Pre-flight: `vzdump.prom` exists and for every VMID in `MW_GUESTS` (default `100 101 200 250`) `now - pve_backup_last_success_timestamp{vmid} < 30*3600`; reboot needed = `/var/run/reboot-required` exists OR `uname -r` ≠ newest installed `proxmox-kernel-*` version (parse `dpkg-query -W 'proxmox-kernel-*-pve-signed'`). Then `apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold full-upgrade`, `systemctl reboot` (after `sleep 2` so the SSH session returns). Env overrides for tests: `MW_PROM_FILE`, `MW_REBOOT_REQUIRED_FILE`, `MW_KERNEL_RUNNING`, `MW_KERNEL_INSTALLED_CMD`, `MW_DRY_RUN=1` (log instead of apt/reboot).
- Workflow: `on: schedule '0 10 * * 0'` + `workflow_dispatch` (input `force: boolean` → skips the "nothing to do" exit only, never the backup gate). Jobs: `maintenance` (connect-proxmox → scp script → run `--check` to decide (exit 3 → summary "nothing to do", stop) → run for real → reconnect loop: every 20 s up to 30 min `ssh -o ConnectTimeout=5 root@192.168.1.223 'uptime -s'` until the boot time is newer than the pre-reboot one → wait up to 15 min for `qm list`/`pct list` to show HC_GUESTS running → `bash scripts/openbao/unseal-ci.sh` if secret present (kubeconfig from Pulumi as in Task 4)); then `uses: ./.github/workflows/health-check.yml` with `secrets: inherit`; `report` job on failure opens/updates issue labelled `maintenance-failed` (same script shape as restore-drill).

- [ ] **Step 1: Write the failing test** (`test_maintenance_reboot.sh`, stubs apt-get/systemctl/dpkg-query/uname via PATH; prom fixture written per test): `refuses_without_backup_metrics` (no prom → exit 1, no apt call), `refuses_on_stale_backup` (one vmid 40 h old → exit 1), `nothing_to_do_exits_3` (fresh backups, no reboot-required, kernels match → exit 3, no apt call), `kernel_mismatch_triggers` (running 7.0.2-4-pve vs installed 7.0.14-17 → apt full-upgrade + reboot called), `reboot_required_file_triggers`, `check_mode_never_mutates` (`--check` → exit 0, no apt/reboot calls).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement script, unseal-ci.sh, workflow.**
- [ ] **Step 4: Run test + shellcheck + actionlint.** Expected: `PASS`, clean.
- [ ] **Step 5: Commit** `ci: monthly maintenance-window workflow with backup gate, reconnect loop, OpenBao unseal`.

### Task 6: Oracle — reboot after backup, Valheim updater + rollback, off-box backups

**Files:**
- Modify: `oracle-cloud-server/ansible/ansible.cfg` (`roles_path = ./roles:../../ansible/roles`)
- Modify: `oracle-cloud-server/ansible/roles/base/tasks/main.yml` (replace the inline `20auto-upgrades` copy with `import_role: unattended_upgrades` — Ubuntu origins + `origin=Tailscale`, `auto_reboot: true`, `reboot_time: "10:15"`; add `tailscale set --auto-update=true`; install `rclone`)
- Create: `oracle-cloud-server/ansible/roles/valheim/templates/valheim-update.sh.j2`, `valheim-update.service.j2`, `valheim-update.timer.j2`, `valheim-rollback.sh.j2`, `rclone.conf.j2`
- Modify: `oracle-cloud-server/ansible/roles/valheim/templates/valheim-backup.sh.j2` (append rclone sync, guarded by `[ -f /opt/valheim/rclone.conf ]`)
- Modify: `oracle-cloud-server/ansible/roles/valheim/tasks/backup.yml` (install rclone.conf, update scripts, enable timer), `defaults/main.yml` (`valheim_backup_bucket: valheim-backups`, `valheim_update_on_calendar: "*-*-* 10:00:00"`)
- Create: `oracle-cloud-server/terraform/backups.tf` (`oci_objectstorage_bucket` `valheim-backups` with lifecycle rule delete 30 d; `oci_identity_dynamic_group` matching `instance.id = '<oracle_server.id>'`; `oci_identity_policy` `Allow dynamic-group <dg> to manage objects in compartment id <id> where target.bucket.name='valheim-backups'`), `outputs.tf` gains `backup_bucket`
- Create: `oracle-cloud-server/ansible/roles/valheim/tests/test_valheim_update.sh` (renders the j2 with `ansible-playbook` on localhost like Task 1, then runs the rendered script with stubbed `DepotDownloader`, `systemctl`, `rsync`, `sha256sum`)

**Interfaces:**
- `valheim-update.sh`: `set -euo pipefail`; `before=$(sha256sum server/valheim_server.x86_64)`; `rsync -a --delete server/ server.prev/`; run DepotDownloader; `after=…`; if changed → `systemctl restart valheim`; log one line either way. Non-zero DepotDownloader exit → exit 1 **after** `server.prev` was taken and **without** restart.
- `valheim-rollback.sh`: `systemctl stop valheim; rsync -a --delete server.prev/ server/; systemctl start valheim`.
- `rclone.conf`: `[oos]\ntype = oracleobjectstorage\nprovider = instance_principal\nnamespace = {{ valheim_oci_namespace }}\ncompartment = {{ valheim_oci_compartment_ocid }}\nregion = {{ valheim_oci_region }}` — the three values come from `group_vars/all.yml` via env in `oracle-deploy.yml` (`OCI_NAMESPACE`, `OCI_COMPARTMENT_OCID`, `OCI_REGION` secrets already exist for Terraform; pass them as `-e` or env lookups).

- [ ] **Step 1: Write the failing updater test** with cases `restarts_only_when_binary_changes`, `no_restart_when_unchanged`, `download_failure_keeps_prev_and_service` (DepotDownloader stub exits 1 → script exit 1, `rsync … server.prev/` called once, no `systemctl restart`), `rollback_swaps_prev_back`.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** templates, tasks, Terraform.
- [ ] **Step 4: Verify.** Run: `bash oracle-cloud-server/ansible/roles/valheim/tests/test_valheim_update.sh && (cd oracle-cloud-server/ansible && ansible-lint) && (cd oracle-cloud-server/terraform && terraform init -backend=false >/dev/null && terraform fmt -check -recursive && terraform validate)` Expected: `PASS`; lint clean; `Success! The configuration is valid.`
- [ ] **Step 5: Commit** `feat(oracle): auto-reboot after world backup, daily Valheim updater with rollback, rclone off-box backups`.

### Task 7: Docs + PR

**Files:**
- Create: `docs/2026-11-04-os-auto-patching.md` (what runs where and when — a table of all timers: 01:00 vzdump, 04:30/04:45 LXC reboots, 06:00 MT Renovate, 09:30 UTC Valheim backup, 10:00 UTC Valheim update, 10:15 UTC Oracle reboot, Sundays 10:00 UTC maintenance window, 1st 10:00 UTC drill; how to run a window by hand; the OpenBao unseal secret decision; first-run expectations: pve1 reboots into 7.0.14, ~76+74+150 packages).
- Modify: `README.md` (Tailscale LXC is now Ansible-managed for in-container config), `CLAUDE.md` (Network table unchanged; add "Maintenance" command lines: `gh workflow run maintenance-window.yml`, `gh workflow run health-check.yml`).

- [ ] **Step 1: Write.**
- [ ] **Step 2: Full verification.** Run every test command from Tasks 1, 4, 5, 6 plus `cd ansible && ansible-lint` and `actionlint .github/workflows/*.yml`. Expected: all `PASS`/clean.
- [ ] **Step 3: Commit, push, open PR** `feat: unattended OS patching for pve1/LXCs/Oracle, maintenance window + health check (PR 3/5)` with base `feat/auto-patching` (stacked on PR 1) and a body that lists the owner decisions (OpenBao unseal secret; Tailscale LXC definition stays manual).
