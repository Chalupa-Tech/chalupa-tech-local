#!/usr/bin/env bash
# Maintenance-window step that runs ON pve1 as root: full package upgrade and
# a reboot, but only when (a) every backed-up guest has a vzdump success
# younger than MW_MAX_BACKUP_AGE and (b) a reboot is actually pending
# (/var/run/reboot-required, or the running kernel is older than the newest
# installed proxmox-kernel).
#
#   maintenance-reboot.sh [--check] [--force]
#     --check   decide and report only; never upgrades or reboots
#     --force   skip the "nothing to do" exit (still gated on backups)
# Exit codes: 0 rebooting (or, with --check, "would reboot"); 3 nothing to
# do; 1 pre-flight refused. The backup gate is never bypassed.
set -euo pipefail

MW_PROM_FILE="${MW_PROM_FILE:-/var/lib/prometheus/node-exporter/vzdump.prom}"
MW_REBOOT_REQUIRED_FILE="${MW_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}"
MW_GUESTS="${MW_GUESTS:-100 101 200 250}"
MW_MAX_BACKUP_AGE="${MW_MAX_BACKUP_AGE:-108000}"   # 30 h in seconds

check=0 force=0
for arg in "$@"; do
  case "$arg" in
    --check) check=1 ;;
    --force) force=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '[maintenance] %s\n' "$*"; }
refuse() { printf '[maintenance] REFUSED: %s\n' "$*" >&2; exit 1; }

# --- Gate 1: every guest has a fresh successful backup -----------------------
[ -f "$MW_PROM_FILE" ] || refuse "no backup metrics at $MW_PROM_FILE — no vzdump has ever succeeded on this host"
now=$(date +%s)
for id in $MW_GUESTS; do
  # `|| true`: under pipefail a no-match grep would abort the script before refuse().
  ts=$( { grep -E "^pve_backup_last_success_timestamp\{vmid=\"$id\"," "$MW_PROM_FILE" || true; } | awk '{print $2}' | sort -n | tail -n 1)
  [ -n "$ts" ] || refuse "no successful backup recorded for vmid $id"
  age=$((now - ts))
  [ "$age" -le "$MW_MAX_BACKUP_AGE" ] || refuse "backup of vmid $id is ${age}s old (limit ${MW_MAX_BACKUP_AGE}s)"
done
log "backup gate passed for guests: $MW_GUESTS"

# --- Gate 2: is a reboot actually pending? ----------------------------------
running=$(uname -r)                                  # e.g. 7.0.14-17-pve
newest=$( { dpkg-query -W -f '${Package}\t${Version}\n' 'proxmox-kernel-*-pve-signed' 2>/dev/null || true; } \
  | awk -F'\t' '{print $2}' | sort -V | tail -n 1)   # e.g. 7.0.14-17
reason=""
if [ -e "$MW_REBOOT_REQUIRED_FILE" ]; then
  reason="$MW_REBOOT_REQUIRED_FILE present"
elif [ -n "$newest" ] && [ "${running%-pve}" != "$newest" ]; then
  reason="running kernel ${running} older than installed ${newest}"
fi

if [ -z "$reason" ] && [ "$force" -eq 0 ]; then
  log "nothing to do: kernel ${running} is current and no reboot is required"
  exit 3
fi
[ -n "$reason" ] || reason="--force"

if [ "$check" -eq 1 ]; then
  log "would reboot: $reason"
  exit 0
fi

# --- Act ---------------------------------------------------------------------
log "upgrading packages ($reason)"
# apt runs in a transient systemd unit, detached from this SSH session: if
# the upgrade restarts networking and the session drops, dpkg keeps going
# instead of being SIGHUP'd mid-transaction. --wait keeps this script
# blocked until it finishes. No autoremove on the hypervisor.
systemd-run --wait --pipe --collect --unit=maintenance-apt-update \
  --setenv=DEBIAN_FRONTEND=noninteractive apt-get update -q
systemd-run --wait --pipe --collect --unit=maintenance-apt-upgrade \
  --setenv=DEBIAN_FRONTEND=noninteractive \
  apt-get -y -q -o Dpkg::Options::=--force-confold full-upgrade
log "rebooting pve1 now ($reason)"
# Short pause so the calling SSH session collects this output first;
# `systemctl reboot` returns immediately and Proxmox stops guests in reverse
# startup order. The SSH session is torn down a few seconds later — the
# workflow treats a dropped connection after this line as expected.
sleep "${MW_REBOOT_DELAY:-2}"
systemctl reboot
exit 0
