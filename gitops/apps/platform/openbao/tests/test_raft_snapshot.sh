#!/usr/bin/env bash
# Unit tests for files/raft-snapshot.sh with a stubbed `bao`.
# Stub semantics mirror the real CLI: `bao status -format=json` exits 2 while
# sealed; `bao write -field=token auth/kubernetes/login ...` prints a token;
# `bao operator raft snapshot save <file>` writes a real snapshot archive
# (tar.gz of meta.json, state.bin, SHA256SUMS; STUB_SNAPSHOT_BYTES=0 writes an
# empty file, STUB_CORRUPT=1 writes an archive whose SHA256SUMS do not match).
# There is NO `snapshot inspect` subcommand in OpenBao (2.6/2.7): the stub
# rejects it like the real CLI, which prints the subcommand help and exits 1.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../files/raft-snapshot.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/sa"
echo "jwt-token" > "$tmp/sa/token"
export CALL_LOG="$tmp/calls.log" OUT_DIR="$tmp/openbao" KEEP=48 SA_TOKEN_FILE="$tmp/sa/token" BAO_ADDR=http://openbao-active.openbao.svc:8200
cat > "$tmp/bin/bao" <<'STUB'
#!/usr/bin/env bash
printf 'bao %s\n' "$*" >> "$CALL_LOG"
case "$*" in
  "status -format=json")
    if [ "${STUB_SEALED:-0}" = 1 ]; then echo '{"sealed":true}'; exit 2; else echo '{"sealed":false}'; exit 0; fi ;;
  "write -field=token auth/kubernetes/login role=openbao-snapshot jwt="*)
    [ "${STUB_SEALED:-0}" = 1 ] && { echo "Vault is sealed" >&2; exit 2; }
    [ -n "${BAO_TOKEN:-}" ] && { echo "unexpected token during login" >&2; exit 1; }
    echo "hvs.stub-token" ;;
  "operator raft snapshot save "*)
    [ "${BAO_TOKEN:-}" = hvs.stub-token ] || { echo "permission denied" >&2; exit 2; }
    f="${!#}"
    if [ "${STUB_SNAPSHOT_BYTES:-4096}" = 0 ]; then : > "$f"; exit 0; fi
    d=$(mktemp -d); echo '{"Version":1,"ID":"stub"}' > "$d/meta.json"; head -c 4096 /dev/zero > "$d/state.bin"
    (cd "$d" && sha256sum meta.json state.bin > SHA256SUMS)
    [ "${STUB_CORRUPT:-0}" = 1 ] && echo "tampered" >> "$d/state.bin"
    tar -C "$d" -czf "$f" meta.json state.bin SHA256SUMS; rm -rf "$d" ;;
  "operator raft snapshot inspect "*)
    echo "Usage: bao operator raft snapshot <subcommand> [options] [args]" >&2; exit 1 ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/bao"
export PATH="$tmp/bin:$PATH"
fail() { echo "FAIL: $1"; exit 1; }
reset() { rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"; : > "$CALL_LOG"; unset STUB_SEALED STUB_SNAPSHOT_BYTES STUB_CORRUPT BAO_TOKEN; }
# `sh`, like the CronJob: the OpenBao image has no bash.
run() { set +e; sh "$script" >"$tmp/out" 2>&1; rc=$?; set -e; return $rc; }
count() { find "$OUT_DIR" -name 'raft-*.snap' | wc -l | tr -d ' '; }

saves_and_prunes() {
  reset
  for i in $(seq 10 59); do head -c 10 /dev/zero > "$OUT_DIR/raft-202601010${i}.snap"; done
  rc=0; run || rc=$?; [ $rc = 0 ] || fail "saves_and_prunes: rc $rc: $(cat "$tmp/out")"
  [ "$(count)" = 48 ] || fail "saves_and_prunes: expected 48 snapshots, got $(count)"
  ! grep -q 'operator raft snapshot inspect' "$CALL_LOG" || fail "saves_and_prunes: called the non-existent 'snapshot inspect' subcommand"
  grep -q 'verified' "$tmp/out" || fail "saves_and_prunes: no verification message: $(cat "$tmp/out")"
  grep -q 'write -field=token auth/kubernetes/login role=openbao-snapshot jwt=jwt-token' "$CALL_LOG" || fail "saves_and_prunes: login args: $(grep login "$CALL_LOG" || true)"
}
fails_when_sealed() {
  reset; export STUB_SEALED=1
  rc=0; run || rc=$?; [ $rc = 1 ] || fail "fails_when_sealed: rc $rc"
  [ "$(count)" = 0 ] || fail "fails_when_sealed: wrote a snapshot while sealed"
  grep -qi 'sealed' "$tmp/out" || fail "fails_when_sealed: message: $(cat "$tmp/out")"
}
fails_on_empty_snapshot() {
  reset; export STUB_SNAPSHOT_BYTES=0
  rc=0; run || rc=$?; [ $rc = 1 ] || fail "fails_on_empty_snapshot: rc $rc"
  [ "$(count)" = 0 ] || fail "fails_on_empty_snapshot: kept an empty snapshot: $(ls "$OUT_DIR")"
}
fails_on_corrupt_snapshot() {
  reset; export STUB_CORRUPT=1
  rc=0; run || rc=$?; [ $rc = 1 ] || fail "fails_on_corrupt_snapshot: rc $rc"
  [ "$(count)" = 0 ] || fail "fails_on_corrupt_snapshot: kept a snapshot whose SHA256SUMS do not match"
  grep -qi 'sha256\|checksum\|verif' "$tmp/out" || fail "fails_on_corrupt_snapshot: message: $(cat "$tmp/out")"
}
no_token_in_logs() {
  reset; rc=0; run || rc=$?
  ! grep -q 'hvs.stub-token' "$tmp/out" || fail "no_token_in_logs: token printed"
}

for t in saves_and_prunes fails_when_sealed fails_on_empty_snapshot fails_on_corrupt_snapshot no_token_in_logs; do
  "$t"; echo "ok $t"
done
echo PASS
