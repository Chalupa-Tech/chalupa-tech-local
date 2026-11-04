#!/usr/bin/env bash
# Unit tests for ensure-vzdump-job.sh with a stubbed `pvesh` on PATH.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../ensure-vzdump-job.sh"
fixtures="$here/fixtures"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/pvesh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "get" ]; then cat "$PVESH_FIXTURE"; exit 0; fi
printf '%s\n' "$*" >> "$PVESH_LOG"
STUB
chmod +x "$tmp/bin/pvesh"
export PATH="$tmp/bin:$PATH"
export PVESH_LOG="$tmp/pvesh.log"

fail() { echo "FAIL: $1"; exit 1; }
run() { : > "$PVESH_LOG"; PVESH_FIXTURE="$fixtures/$1" bash "$script" "${@:2}"; }
# shellcheck disable=SC2054  # comma-joined values are single CLI arguments
common=(--id nightly-guests --schedule 01:00 --vmids 100,101,200,250)
mutations() { grep -cE '^(create|set|delete) ' "$PVESH_LOG" || true; }

creates_when_absent() {
  out=$(run none.json "${common[@]}" --storage local --prune keep-last=1)
  [ "${out##*$'\n'}" = CHANGED ] || fail "creates_when_absent: verdict '$out'"
  [ "$(mutations)" = 1 ] || fail "creates_when_absent: expected 1 mutation, got $(mutations)"
  line=$(grep '^create /cluster/backup' "$PVESH_LOG") || fail "creates_when_absent: no create call"
  for want in '--id nightly-guests' '--schedule 01:00' '--vmid 100,101,200,250' '--storage local' '--prune-backups keep-last=1' '--mode snapshot' '--compress zstd' '--enabled 1' '--notification-mode notification-system' "--notes-template {{guestname}}"; do
    [[ "$line" == *"$want"* ]] || fail "creates_when_absent: create missing '$want' in: $line"
  done
}

deletes_legacy() {
  out=$(run legacy.json "${common[@]}" --storage local --prune keep-last=1 --delete-id backup-af8b79f5-6e9a)
  [ "${out##*$'\n'}" = CHANGED ] || fail "deletes_legacy: verdict"
  [ "$(sed -n 1p "$PVESH_LOG")" = "delete /cluster/backup/backup-af8b79f5-6e9a" ] || fail "deletes_legacy: first call not delete: $(sed -n 1p "$PVESH_LOG")"
  grep -q '^create /cluster/backup' "$PVESH_LOG" || fail "deletes_legacy: no create after delete"
}

noop_when_current() {
  out=$(run current.json "${common[@]}" --storage local --prune keep-last=1 --delete-id backup-af8b79f5-6e9a)
  [ "${out##*$'\n'}" = UNCHANGED ] || fail "noop_when_current: verdict '$out'"
  [ "$(mutations)" = 0 ] || fail "noop_when_current: mutations: $(cat "$PVESH_LOG")"
}

updates_drifted_job() {
  out=$(run drifted-storage.json "${common[@]}" --storage truenas-backups --prune keep-last=7,keep-weekly=4)
  [ "${out##*$'\n'}" = CHANGED ] || fail "updates_drifted_job: verdict"
  [ "$(mutations)" = 1 ] || fail "updates_drifted_job: expected 1 mutation"
  line=$(grep '^set /cluster/backup/nightly-guests' "$PVESH_LOG") || fail "updates_drifted_job: no set call"
  [[ "$line" == *"--storage truenas-backups"* && "$line" == *"--prune-backups keep-last=7,keep-weekly=4"* ]] || fail "updates_drifted_job: set args: $line"
}

vmid_order_is_noop() {
  out=$(run vmid-reordered.json "${common[@]}" --storage local --prune keep-last=1)
  [ "${out##*$'\n'}" = UNCHANGED ] || fail "vmid_order_is_noop: verdict '$out'"
}

check_mode_mutates_nothing() {
  out=$(run none.json "${common[@]}" --storage local --prune keep-last=1 --check)
  [ "${out##*$'\n'}" = CHANGED ] || fail "check_mode_mutates_nothing: verdict '$out'"
  [ "$(mutations)" = 0 ] || fail "check_mode_mutates_nothing: mutated: $(cat "$PVESH_LOG")"
  out=$(run drifted-storage.json "${common[@]}" --storage truenas-backups --prune keep-last=7,keep-weekly=4 --check)
  [ "${out##*$'\n'}" = CHANGED ] || fail "check_mode_mutates_nothing(drift): verdict"
  [ "$(mutations)" = 0 ] || fail "check_mode_mutates_nothing(drift): mutated"
}

for t in creates_when_absent deletes_legacy noop_when_current updates_drifted_job vmid_order_is_noop check_mode_mutates_nothing; do
  "$t"; echo "ok $t"
done
echo PASS
