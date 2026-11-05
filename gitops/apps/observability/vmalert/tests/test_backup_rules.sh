#!/usr/bin/env bash
# Structural checks on the rendered backups VMRule: every expected guest has
# its own never-succeeded alert, and the failed-backup rule also fires when a
# guest has a failure but no success series at all.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$(helm template vmalert "$here/.." 2>/dev/null)
fail() { echo "FAIL: $1"; exit 1; }
for vmid in 100 101 200 250; do
  grep -q "absent(pve_backup_last_success_timestamp{job=\"proxmox-host\",vmid=\"$vmid\"})" <<<"$out" || fail "no never-succeeded rule for vmid $vmid"
done
grep -q 'alert: ProxmoxBackupNeverSucceeded' <<<"$out" || fail "ProxmoxBackupNeverSucceeded missing"
grep -A1 'alert: ProxmoxBackupFailed' <<<"$out" | grep -q 'unless ignoring(storage) pve_backup_last_success_timestamp' || fail "ProxmoxBackupFailed lacks the unless clause"
! grep -q 'alert: ProxmoxBackupMetricsAbsent' <<<"$out" || fail "global MetricsAbsent rule should be replaced by per-VMID rules"
echo PASS
