# OS auto-patching: pve1, the LXCs and the Oracle VM

**Date:** 2026-11-04
**PR:** #TBD (PR 3 of the auto-patching series —
`docs/superpowers/specs/2026-11-04-auto-patching-design.md`, rings 3/4/6)

## Why

The 2026-11-04 audit found 76 pending packages on `pve1` (kernel running
7.0.2-4 with 7.0.14-17 installed, 129 days up), 74 on the Plex LXC
(`reboot-required` set), 150 on the Tailscale LXC (not under any
configuration management at all), and an Oracle VM that installed security
updates but never rebooted into them. Host packages were only ever applied
when a Stage 1 run happened to touch `proxmox_prep` (PR 1 removed that).

## What runs where, and when

| When (local = America/Denver) | System | What | Where it lives |
|---|---|---|---|
| daily, apt-daily timers | pve1 | `unattended-upgrades`: Debian security + updates, Proxmox repo. **Never reboots.** | `ansible/roles/proxmox_prep` → `unattended_upgrades` role |
| 01:00 | pve1 | vzdump of 100/101/200/250 (PR 1) | `proxmox_prep/tasks/backups.yml` |
| 04:30 (11:30 UTC — the container runs UTC) | Plex LXC 200 | reboot if `/var/run/reboot-required` (Ubuntu security/updates + Plex repo applied daily) | `lxc_baseline` in `playbooks/vm-configure.yml` |
| 04:45 | Tailscale LXC 100 | same, Ubuntu + `origin=Tailscale`; `tailscale set --auto-update=true`. Drops the CI subnet route for ~1 min | `lxc_baseline`, host `tailscale` (pct exec via pve1) |
| 06:00 | cluster | Renovate (unchanged) | `gitops/apps/infra-tools/renovate` |
| 09:30 UTC | Oracle | world backup (+ `rclone sync` to bucket `valheim-backups`) | `valheim-backup.timer` |
| 10:00 UTC | Oracle | `valheim-update.timer`: pull current Steam build, keep `server.prev`, restart only if changed | `valheim-update.sh` |
| 10:15 UTC | Oracle | reboot if required (Ubuntu security/updates + Tailscale applied daily) | `base` role → `unattended_upgrades` |
| Sundays 10:00 UTC | pve1 | **maintenance window**: full-upgrade + reboot, only if a reboot is pending and every guest backup is < 30 h old; then health check | `.github/workflows/maintenance-window.yml` |
| 1st, 12:00 UTC | pve1 | restore drill (PR 1; shares the `pve1-host-ops` concurrency group with the maintenance window) | `.github/workflows/restore-drill.yml` |

## The maintenance window, step by step

1. `scripts/proxmox/maintenance-reboot.sh --check` on pve1: refuses (exit 1)
   unless `vzdump.prom` shows a success < 30 h old for every guest; exits 3
   "nothing to do" unless `/var/run/reboot-required` exists or the running
   kernel is older than the newest installed `proxmox-kernel`. `--force`
   (dispatch input) skips only the nothing-to-do exit, never the backup gate.
2. Real run: `apt-get full-upgrade`, `autoremove`, `systemctl reboot`.
   Proxmox shuts guests down in reverse startup order.
3. The runner loses the LAN (its only route is the Tailscale LXC's subnet
   route) and polls `uptime -s` for up to 30 min until the boot time changes,
   then waits up to 15 min for 100/101/200/250 to be `running`, then for all
   six Talos nodes Ready.
4. OpenBao: replicas unseal themselves after the reboot (OCI KMS auto-unseal,
   `docs/2026-11-05-openbao-auto-unseal.md`); the health check's retries
   cover the minute that takes. On a cluster that has not migrated yet,
   `scripts/openbao/unseal-ci.sh` unseals with `OPENBAO_UNSEAL_KEYS` if that
   secret exists; otherwise the `OpenBaoSealed` alert (PR 2) fires until
   someone runs `scripts/openbao/unseal.sh`.
5. `health-check.yml` (reusable; also `gh workflow run health-check.yml`):
   pve1 SSH, guests running, Talos nodes, ArgoCD apps Healthy, OpenBao
   unsealed, ExternalSecrets Ready, Plex `/identity`, HA HTTP, TrueNAS NFS.
6. Any failure opens/updates a `maintenance-failed` issue.

Run it by hand: `gh workflow run maintenance-window.yml` (add `-f force=true`
to reboot without a pending update).

## First run expectations

- pve1 reboots into kernel 7.0.14-x and applies the 76 pending packages the
  next Sunday after merge (or on dispatch). Everything is down for a few
  minutes; the Talos cluster and TrueNAS come back on their own.
- The LXCs apply their backlog on the first `apt-daily-upgrade` run (around
  06:00 local, randomised) and reboot at the next 04:30/04:45 window, i.e.
  the following night.
- The Oracle VM reboots at 10:15 UTC the first day `reboot-required` is set.
- `openbao-2` has been sealed since September; the seal-migration runbook
  (`docs/runbooks/openbao-seal-migration.md`) restarts and unseals it as its
  first step.

## Decisions

- **OpenBao unseal** — decided 2026-11-05: OCI KMS auto-unseal
  (`docs/2026-11-05-openbao-auto-unseal.md`), which makes host reboots and
  (PR 4) Talos node upgrades fully unattended with no key material in CI.
  Until the migration runbook has run, `OPENBAO_UNSEAL_KEYS` (3 of 5 Shamir
  shares) is an optional stop-gap; without either, ExternalSecrets stop
  syncing after every pve1 reboot until a human unseals.
- **pve1 never auto-reboots** — only the gated Sunday window does.
- **Tailscale LXC definition stays manual** (`protection: 1`); Ansible only
  manages the in-container patch policy, over `pct exec` (no SSH key inside).
- **Plex version pin dropped** (`plexmediaserver` `state: present`): PR #404's
  pin was a one-off "bump to latest"; with unattended-upgrades applying Plex
  releases, a pin would make Stage 3 downgrade.
- **Valheim server build updates daily** instead of only on Ansible runs.
  Mods are still pinned, so a game update that breaks BepInEx is the same
  risk as before — now with `sudo /opt/valheim/valheim-rollback.sh`.
- **Oracle off-box backups** use instance-principal auth (`terraform/
  backups.tf`: bucket with 30-day expiry, dynamic group, policy). No keys on
  the box. Requires the Terraform user to be allowed to create dynamic
  groups/policies in the tenancy.

## Verification (local, 2026-11-04)

`ansible-lint` clean in both trees; `site.yml --check --diff` against pve1
shows the unattended-upgrades templates; `vm-configure.yml --check --limit
tailscale` reaches VMID 100 over `pct` and renders the Tailscale profile;
`terraform validate` passes. Unit tests: `ansible/roles/unattended_upgrades/
tests/test_render.sh`, `scripts/tests/test_health_check.sh`,
`scripts/proxmox/tests/test_maintenance_reboot.sh`,
`oracle-cloud-server/ansible/roles/valheim/tests/test_valheim_update.sh`.
