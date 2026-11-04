#!/usr/bin/env bash
# Unit tests for maintenance-reboot.sh with stubbed apt-get/systemctl/dpkg-query/uname.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../maintenance-reboot.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export MW_LOG="$tmp/calls.log"
export MW_PROM_FILE="$tmp/vzdump.prom"
export MW_REBOOT_REQUIRED_FILE="$tmp/reboot-required"
export MW_GUESTS="100 101 200 250"
export MW_REBOOT_DELAY=0

# shellcheck disable=SC2016  # stub body is meant to be literal
for c in apt-get systemctl; do printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$MW_LOG"\n' "$c" > "$tmp/bin/$c"; done
cat > "$tmp/bin/uname" <<'STUB'
#!/usr/bin/env bash
echo "${MW_STUB_RUNNING:-7.0.14-17-pve}"
STUB
cat > "$tmp/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
printf 'dpkg-query %s\n' "$*" >> "$MW_LOG"
# name<TAB>version, like dpkg-query -W -f '${Package}\t${Version}\n'
printf 'proxmox-kernel-7.0.2-4-pve-signed\t7.0.2-4\n'
printf 'proxmox-kernel-%s-signed\t%s\n' "${MW_STUB_INSTALLED:-7.0.14-17-pve}" "${MW_STUB_INSTALLED_VER:-7.0.14-17}"
STUB
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

fail() { echo "FAIL: $1"; exit 1; }
fresh_prom() { # all guests fresh unless $1 = stale vmid
  local now; now=$(date +%s); : > "$MW_PROM_FILE"
  for id in 100 101 200 250; do
    ts=$now; [ "${1:-}" = "$id" ] && ts=$((now - 40 * 3600))
    echo "pve_backup_last_success_timestamp{vmid=\"$id\",storage=\"nvme-backups\"} $ts" >> "$MW_PROM_FILE"
  done
}
reset() { : > "$MW_LOG"; rm -f "$MW_PROM_FILE" "$MW_REBOOT_REQUIRED_FILE"; unset MW_STUB_RUNNING MW_STUB_INSTALLED MW_STUB_INSTALLED_VER; }
mutations() { grep -cE '^(apt-get|systemctl reboot)' "$MW_LOG" || true; }
run() { set +e; bash "$script" "$@" >"$tmp/out" 2>&1; rc=$?; set -e; return $rc; }

refuses_without_backup_metrics() {
  reset; touch "$MW_REBOOT_REQUIRED_FILE"
  rc=0; run || rc=$?; [ $rc = 1 ] || fail "refuses_without_backup_metrics: rc $rc: $(cat "$tmp/out")"
  [ "$(mutations)" = 0 ] || fail "refuses_without_backup_metrics: mutated"
  grep -q 'no backup metrics' "$tmp/out" || fail "refuses_without_backup_metrics: message: $(cat "$tmp/out")"
}
refuses_on_stale_backup() {
  reset; fresh_prom 101; touch "$MW_REBOOT_REQUIRED_FILE"
  rc=0; run || rc=$?; [ $rc = 1 ] || fail "refuses_on_stale_backup: rc $rc"
  [ "$(mutations)" = 0 ] || fail "refuses_on_stale_backup: mutated"
  grep -q 'vmid 101' "$tmp/out" || fail "refuses_on_stale_backup: should name vmid 101: $(cat "$tmp/out")"
}
refuses_on_missing_guest_metric() {
  reset; fresh_prom; sed -i '' '/vmid="200"/d' "$MW_PROM_FILE"; touch "$MW_REBOOT_REQUIRED_FILE"
  rc=0; run || rc=$?; [ $rc = 1 ] || fail "refuses_on_missing_guest_metric: rc $rc"
  grep -q 'vmid 200' "$tmp/out" || fail "refuses_on_missing_guest_metric: $(cat "$tmp/out")"
}
nothing_to_do_exits_3() {
  reset; fresh_prom
  rc=0; run || rc=$?; [ $rc = 3 ] || fail "nothing_to_do_exits_3: rc $rc: $(cat "$tmp/out")"
  [ "$(mutations)" = 0 ] || fail "nothing_to_do_exits_3: mutated"
}
kernel_mismatch_triggers() {
  reset; fresh_prom; export MW_STUB_RUNNING=7.0.2-4-pve
  rc=0; run || rc=$?; [ $rc = 0 ] || fail "kernel_mismatch_triggers: rc $rc: $(cat "$tmp/out")"
  grep -q '^apt-get .*full-upgrade' "$MW_LOG" || fail "kernel_mismatch_triggers: no full-upgrade: $(cat "$MW_LOG")"
  grep -q '^systemctl reboot' "$MW_LOG" || fail "kernel_mismatch_triggers: no reboot"
  [ "$(grep -n -E '^(apt-get .*full-upgrade|systemctl reboot)' "$MW_LOG" | cut -d: -f2 | head -1 | cut -d' ' -f1)" = apt-get ] || fail "kernel_mismatch_triggers: reboot before upgrade"
}
reboot_required_file_triggers() {
  reset; fresh_prom; touch "$MW_REBOOT_REQUIRED_FILE"
  rc=0; run || rc=$?; [ $rc = 0 ] || fail "reboot_required_file_triggers: rc $rc: $(cat "$tmp/out")"
  grep -q '^systemctl reboot' "$MW_LOG" || fail "reboot_required_file_triggers: no reboot"
}
force_skips_nothing_to_do_but_not_gate() {
  reset; fresh_prom
  rc=0; run --force || rc=$?; [ $rc = 0 ] || fail "force: rc $rc: $(cat "$tmp/out")"
  grep -q '^systemctl reboot' "$MW_LOG" || fail "force: no reboot"
  reset; touch "$MW_REBOOT_REQUIRED_FILE"
  rc=0; run --force || rc=$?; [ $rc = 1 ] || fail "force without backups: rc $rc (gate must still refuse)"
  [ "$(mutations)" = 0 ] || fail "force without backups: mutated"
}
check_mode_never_mutates() {
  reset; fresh_prom; export MW_STUB_RUNNING=7.0.2-4-pve
  rc=0; run --check || rc=$?; [ $rc = 0 ] || fail "check_mode: rc $rc: $(cat "$tmp/out")"
  [ "$(mutations)" = 0 ] || fail "check_mode: mutated: $(cat "$MW_LOG")"
  grep -q 'would reboot' "$tmp/out" || fail "check_mode: message: $(cat "$tmp/out")"
  reset; fresh_prom
  rc=0; run --check || rc=$?; [ $rc = 3 ] || fail "check_mode nothing-to-do: rc $rc"
}

for t in refuses_without_backup_metrics refuses_on_stale_backup refuses_on_missing_guest_metric nothing_to_do_exits_3 kernel_mismatch_triggers reboot_required_file_triggers force_skips_nothing_to_do_but_not_gate check_mode_never_mutates; do
  "$t"; echo "ok $t"
done
echo PASS
