#!/usr/bin/env bash
# Unit tests for vzdump-metrics-hook.sh. Run from anywhere: bash test_vzdump_hook.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
hook="$here/../vzdump-metrics-hook.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export VZDUMP_METRICS_FILE="$tmp/vzdump.prom"

fail() { echo "FAIL: $1"; exit 1; }
reset() { rm -f "$VZDUMP_METRICS_FILE"; }
run_hook() { STOREID=local TARGET="/var/lib/vz/dump/x.vma.zst" bash "$hook" "$@"; }
count() { grep -c "$1" "$VZDUMP_METRICS_FILE" || true; }

records_success() {
  reset; now=$(date +%s)
  run_hook backup-end snapshot 250
  line=$(grep -E '^pve_backup_last_success_timestamp\{vmid="250",storage="local"\} [0-9]+$' "$VZDUMP_METRICS_FILE") || fail "records_success: no success line"
  ts=${line##* }
  (( ts >= now && ts <= now + 5 )) || fail "records_success: timestamp $ts not within 5s of $now"
  grep -q '^# HELP pve_backup_last_success_timestamp' "$VZDUMP_METRICS_FILE" || fail "records_success: missing HELP"
  grep -q '^# TYPE pve_backup_last_success_timestamp gauge' "$VZDUMP_METRICS_FILE" || fail "records_success: missing TYPE"
}

records_failure() {
  reset
  run_hook backup-abort snapshot 200
  [ "$(count '^pve_backup_last_failure_timestamp{vmid="200",storage="local"} ')" = 1 ] || fail "records_failure: no failure line"
  [ "$(count '^pve_backup_last_success_timestamp{vmid="200"')" = 0 ] || fail "records_failure: unexpected success line"
}

preserves_other_vmids() {
  reset
  run_hook backup-end snapshot 250
  run_hook backup-end snapshot 200
  [ "$(count '^pve_backup_last_success_timestamp{vmid="250"')" = 1 ] || fail "preserves_other_vmids: 250 missing"
  [ "$(count '^pve_backup_last_success_timestamp{vmid="200"')" = 1 ] || fail "preserves_other_vmids: 200 missing"
  [ "$(count '^# HELP pve_backup_last_success_timestamp')" = 1 ] || fail "preserves_other_vmids: duplicated HELP"
}

overwrites_same_vmid() {
  reset
  run_hook backup-end snapshot 250
  first=$(grep '^pve_backup_last_success_timestamp{vmid="250"' "$VZDUMP_METRICS_FILE" | awk '{print $2}')
  sleep 1
  run_hook backup-end snapshot 250
  [ "$(count '^pve_backup_last_success_timestamp{vmid="250"')" = 1 ] || fail "overwrites_same_vmid: duplicate line"
  second=$(grep '^pve_backup_last_success_timestamp{vmid="250"' "$VZDUMP_METRICS_FILE" | awk '{print $2}')
  (( second > first )) || fail "overwrites_same_vmid: timestamp not updated ($first -> $second)"
}

phase_ignored() {
  reset
  run_hook backup-end snapshot 250
  before=$(cat "$VZDUMP_METRICS_FILE")
  for phase in log-end pre-stop job-init job-start job-end backup-start pre-restart post-restart; do
    run_hook "$phase" snapshot 250 || fail "phase_ignored: $phase exited non-zero"
  done
  run_hook job-end || fail "phase_ignored: job-end without args exited non-zero"
  [ "$(cat "$VZDUMP_METRICS_FILE")" = "$before" ] || fail "phase_ignored: file changed"
}

atomic_write() {
  reset
  run_hook backup-end snapshot 250
  run_hook backup-abort snapshot 200
  leftovers=$(find "$tmp" -name 'vzdump.prom*' ! -name 'vzdump.prom' | wc -l | tr -d ' ')
  [ "$leftovers" = 0 ] || fail "atomic_write: temp files left behind"
}

for t in records_success records_failure preserves_other_vmids overwrites_same_vmid phase_ignored atomic_write; do
  "$t"; echo "ok $t"
done
echo PASS
