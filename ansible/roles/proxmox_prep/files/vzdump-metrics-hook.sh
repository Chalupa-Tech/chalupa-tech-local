#!/usr/bin/env bash
# vzdump hook (configured via `script:` in /etc/vzdump.conf). Records, per
# guest, when its last backup succeeded or failed, as node-exporter textfile
# metrics so the existing proxmox-host scrape + vmalert rules can alert on
# stale or failing backups.
#
# Called by vzdump as: <script> <phase> [<mode> <vmid>]   (see
# /usr/share/doc/pve-manager/examples/vzdump-hook-script.pl). Any non-zero
# exit aborts the backup, so every path that is not a bug exits 0.
set -euo pipefail

metrics_file="${VZDUMP_METRICS_FILE:-/var/lib/prometheus/node-exporter/vzdump.prom}"
phase="${1:-}"
vmid="${3:-}"
storage="${STOREID:-unknown}"

case "$phase" in
  backup-end)   metric="pve_backup_last_success_timestamp" ;;
  backup-abort) metric="pve_backup_last_failure_timestamp" ;;
  *)            exit 0 ;;
esac
[ -n "$vmid" ] || exit 0

now=$(date +%s)
new_line="${metric}{vmid=\"${vmid}\",storage=\"${storage}\"} ${now}"

existing=""
if [ -f "$metrics_file" ]; then
  # Keep every sample line except the one we are replacing; headers are
  # regenerated below so they appear exactly once.
  existing=$(grep -vE "^(#|${metric}\{vmid=\"${vmid}\",)" "$metrics_file" || true)
fi

dir=$(dirname "$metrics_file")
mkdir -p "$dir"
tmp=$(mktemp "${dir}/.vzdump.prom.XXXXXX")
{
  echo "# HELP pve_backup_last_success_timestamp Unix time of the last successful vzdump of this guest."
  echo "# TYPE pve_backup_last_success_timestamp gauge"
  echo "# HELP pve_backup_last_failure_timestamp Unix time of the last failed/aborted vzdump of this guest."
  echo "# TYPE pve_backup_last_failure_timestamp gauge"
  [ -n "$existing" ] && printf '%s\n' "$existing"
  echo "$new_line"
} > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$metrics_file"
exit 0
