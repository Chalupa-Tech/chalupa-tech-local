#!/usr/bin/env bash
# shellcheck disable=SC2012  # test fixtures have fixed, safe filenames
# Unit tests for files/pg-dump.sh with a stubbed pg_dumpall and real zstd.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../files/pg-dump.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export OUT_DIR="$tmp/postgres" KEEP=14 MIN_BYTES=10 PGHOST=arrs-pg-rw PGUSER=postgres PGPASSWORD=s3cret-do-not-log
cat > "$tmp/bin/pg_dumpall" <<'STUB'
#!/usr/bin/env bash
printf 'pg_dumpall %s\n' "$*" >> "$STUB_LOG"
[ "${STUB_FAIL:-0}" = 1 ] && { echo "connection refused" >&2; exit 1; }
printf -- '-- PostgreSQL database cluster dump\nCREATE DATABASE radarr_main;\n'
STUB
chmod +x "$tmp/bin/pg_dumpall"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/calls.log"
fail() { echo "FAIL: $1"; exit 1; }
reset() { rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"; : > "$STUB_LOG"; unset STUB_FAIL; }
run() { set +e; bash "$script" >"$tmp/out" 2>&1; rc=$?; set -e; return $rc; }

writes_and_prunes() {
  reset
  for i in $(seq 1 16); do echo x | zstd -q > "$OUT_DIR/arrs-pg-2026010${i}-0000.sql.zst"; done
  rc=0; run || rc=$?; [ $rc = 0 ] || fail "writes_and_prunes: rc $rc: $(cat "$tmp/out")"
  n=$(ls "$OUT_DIR"/arrs-pg-*.sql.zst | wc -l | tr -d ' ')
  [ "$n" = 14 ] || fail "writes_and_prunes: expected 14 files, got $n"
  newest=$(ls -t "$OUT_DIR"/arrs-pg-*.sql.zst | head -1)
  zstd -dc "$newest" | grep -q 'CREATE DATABASE radarr_main' || fail "writes_and_prunes: newest file is not the dump"
  grep -q 'zstd -t' "$tmp/out" || grep -q 'verified' "$tmp/out" || fail "writes_and_prunes: no verification logged"
}
fails_when_dump_fails() {
  reset; export STUB_FAIL=1
  rc=0; run || rc=$?; [ $rc = 1 ] || fail "fails_when_dump_fails: rc $rc"
  [ "$(ls -A "$OUT_DIR" | wc -l | tr -d ' ')" = 0 ] || fail "fails_when_dump_fails: leftover files: $(ls -A "$OUT_DIR")"
}
no_password_in_logs() {
  reset
  rc=0; run || rc=$?
  ! grep -q 's3cret-do-not-log' "$tmp/out" || fail "no_password_in_logs: password appeared in output"
  ! grep -q 's3cret-do-not-log' "$STUB_LOG" || fail "no_password_in_logs: password passed on the command line"
}
uses_host_and_user_env() {
  reset
  rc=0; run || rc=$?
  grep -qE '^pg_dumpall .*(-h arrs-pg-rw|--host[= ]arrs-pg-rw)' "$STUB_LOG" || fail "uses_host_and_user_env: host not passed: $(cat "$STUB_LOG")"
}

for t in writes_and_prunes fails_when_dump_fails no_password_in_logs uses_host_and_user_env; do
  "$t"; echo "ok $t"
done
echo PASS
