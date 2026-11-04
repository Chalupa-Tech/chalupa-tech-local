#!/usr/bin/env bash
# Unit tests for restore-drill.sh with stubbed Proxmox CLIs on PATH.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../restore-drill.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export DRILL_LOG="$tmp/calls.log"
export DRILL_METRICS_FILE="$tmp/restore-drill.prom"

# Stub behaviour is driven by env vars set per test:
#   DRILL_ARCHIVES_<vmid>  whitespace-separated volids pvesm list returns for that vmid
#   DRILL_SCRATCH_EXISTS   "1" => qm/pct status <scratch> succeeds (scratch VMID present)
#   DRILL_QM_CONFIG        what `qm config <scratch>` prints
#   DRILL_PCT_CONFIG       what `pct config <scratch>` prints
cat > "$tmp/bin/pvesm" <<'STUB'
#!/usr/bin/env bash
printf 'pvesm %s\n' "$*" >> "$DRILL_LOG"
case "$1" in
  status) printf 'Name Type Status Total Used Available %%\nlocal dir active 1 1 1 1\nnvme-backups dir active 1 1 1 1\ntruenas-backups nfs active 1 1 1 1\n' ;;
  list)
    storage=$2; vmid=""; while [ $# -gt 0 ]; do [ "$1" = --vmid ] && vmid=$2; shift; done
    var="DRILL_ARCHIVES_${vmid}"; echo "Volid Format Type Size VMID"
    for v in ${!var:-}; do case "$v" in "$storage":*) echo "$v vma.zst backup 1 $vmid" ;; esac; done ;;
  path) echo "/mnt/pve/${2%%:*}/dump/${2##*/}" ;;
esac
STUB
cat > "$tmp/bin/qm" <<'STUB'
#!/usr/bin/env bash
printf 'qm %s\n' "$*" >> "$DRILL_LOG"
case "$1" in
  status) [ "${DRILL_SCRATCH_EXISTS:-0}" = 1 ] ;;
  config) echo "${DRILL_QM_CONFIG:-scsi0: local-lvm:vm-9250-disk-0,size=60G}" ;;
esac
STUB
cat > "$tmp/bin/pct" <<'STUB'
#!/usr/bin/env bash
printf 'pct %s\n' "$*" >> "$DRILL_LOG"
case "$1" in
  status) [ "${DRILL_SCRATCH_EXISTS:-0}" = 1 ] ;;
  config) echo "${DRILL_PCT_CONFIG:-rootfs: local-lvm:vm-9200-disk-0,size=256G}" ;;
esac
STUB
# shellcheck disable=SC2016  # the stub body is meant to be literal
for s in qmrestore zstd; do printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$DRILL_LOG"\n' "$s" > "$tmp/bin/$s"; done
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

fail() { echo "FAIL: $1"; exit 1; }
reset() { : > "$DRILL_LOG"; rm -f "$DRILL_METRICS_FILE"; unset DRILL_SCRATCH_EXISTS DRILL_QM_CONFIG DRILL_PCT_CONFIG; }
all_archives() {
  export DRILL_ARCHIVES_250='nvme-backups:backup/vzdump-qemu-250-2026_10_31-01_00_05.vma.zst truenas-backups:backup/vzdump-qemu-250-2026_11_01-01_00_05.vma.zst'
  export DRILL_ARCHIVES_200='nvme-backups:backup/vzdump-lxc-200-2026_11_01-01_05_00.tar.zst'
  export DRILL_ARCHIVES_101='nvme-backups:backup/vzdump-qemu-101-2026_11_01-01_10_00.vma.zst'
  export DRILL_ARCHIVES_100='nvme-backups:backup/vzdump-lxc-100-2026_11_01-01_12_00.tar.zst'
}

restores_newest_and_destroys() {
  reset; all_archives
  bash "$script" >/dev/null || fail "restores_newest_and_destroys: exit $?"
  grep -q '^qmrestore truenas-backups:backup/vzdump-qemu-250-2026_11_01-01_00_05.vma.zst 9250 --storage local-lvm --unique 1$' "$DRILL_LOG" || fail "restores_newest_and_destroys: qmrestore args: $(grep qmrestore "$DRILL_LOG" || true)"
  grep -q '^pct restore 9200 nvme-backups:backup/vzdump-lxc-200-2026_11_01-01_05_00.tar.zst --storage local-lvm --unique 1$' "$DRILL_LOG" || fail "restores_newest_and_destroys: pct restore args: $(grep 'pct restore' "$DRILL_LOG" || true)"
  [ "$(grep -c '^qm destroy 9250 --purge 1$' "$DRILL_LOG")" = 1 ] || fail "restores_newest_and_destroys: qm destroy count"
  [ "$(grep -c '^pct destroy 9200 --purge 1$' "$DRILL_LOG")" = 1 ] || fail "restores_newest_and_destroys: pct destroy count"
}

fails_when_no_archive() {
  reset; all_archives; export DRILL_ARCHIVES_250=""
  if bash "$script" >/dev/null 2>&1; then fail "fails_when_no_archive: exited 0"; fi
  [ ! -f "$DRILL_METRICS_FILE" ] || fail "fails_when_no_archive: metric written"
}

refuses_existing_scratch() {
  reset; all_archives; export DRILL_SCRATCH_EXISTS=1
  if bash "$script" >/dev/null 2>&1; then fail "refuses_existing_scratch: exited 0"; fi
  ! grep -q '^qmrestore' "$DRILL_LOG" || fail "refuses_existing_scratch: restore attempted"
  ! grep -q '^qm destroy' "$DRILL_LOG" || fail "refuses_existing_scratch: destroyed a pre-existing VM"
}

cleans_up_on_failure() {
  reset; all_archives; export DRILL_QM_CONFIG="name: broken"
  if bash "$script" >/dev/null 2>&1; then fail "cleans_up_on_failure: exited 0"; fi
  [ "$(grep -c '^qm destroy 9250 --purge 1$' "$DRILL_LOG")" = 1 ] || fail "cleans_up_on_failure: destroy count $(grep -c 'qm destroy' "$DRILL_LOG" || true)"
  [ ! -f "$DRILL_METRICS_FILE" ] || fail "cleans_up_on_failure: metric written"
}

verify_only_runs_zstd() {
  reset; all_archives
  bash "$script" >/dev/null || fail "verify_only_runs_zstd: exit"
  grep -q '^zstd -t /mnt/pve/nvme-backups/dump/vzdump-qemu-101-2026_11_01-01_10_00.vma.zst$' "$DRILL_LOG" || fail "verify_only_runs_zstd: 101 not verified: $(grep zstd "$DRILL_LOG" || true)"
  grep -q '^zstd -t /mnt/pve/nvme-backups/dump/vzdump-lxc-100-2026_11_01-01_12_00.tar.zst$' "$DRILL_LOG" || fail "verify_only_runs_zstd: 100 not verified"
}

writes_metric_on_success() {
  reset; all_archives; now=$(date +%s)
  bash "$script" >/dev/null || fail "writes_metric_on_success: exit"
  line=$(grep -E '^pve_restore_drill_last_success_timestamp [0-9]+$' "$DRILL_METRICS_FILE") || fail "writes_metric_on_success: no metric"
  ts=${line##* }; (( ts >= now && ts <= now + 60 )) || fail "writes_metric_on_success: ts $ts"
}

only_scratch_ids_destroyed() {
  reset; all_archives
  bash "$script" >/dev/null || fail "only_scratch_ids_destroyed: exit"
  bad=$(grep -E '^(qm|pct) destroy ' "$DRILL_LOG" | grep -vE ' (9250|9200) ' || true)
  [ -z "$bad" ] || fail "only_scratch_ids_destroyed: $bad"
}

for t in restores_newest_and_destroys fails_when_no_archive refuses_existing_scratch cleans_up_on_failure verify_only_runs_zstd writes_metric_on_success only_scratch_ids_destroyed; do
  "$t"; echo "ok $t"
done
echo PASS
