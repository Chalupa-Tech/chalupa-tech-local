#!/usr/bin/env bash
# Unit tests for files/valheim-update.sh and files/valheim-rollback.sh with
# stubbed DepotDownloader and systemctl; real rsync.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
update="$here/../files/valheim-update.sh"
rollback="$here/../files/valheim-rollback.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/valheim/server" "$tmp/valheim/dist/depotdownloader-3.4.0"
export CALL_LOG="$tmp/calls.log"
export VALHEIM_HOME="$tmp/valheim"
export VALHEIM_SERVER_DIR="$tmp/valheim/server"
export VALHEIM_DEPOTDOWNLOADER="$tmp/valheim/dist/depotdownloader-3.4.0/DepotDownloader"
export VALHEIM_APP_ID=896660

# DepotDownloader stub: DD_MODE=same|new|fail
cat > "$VALHEIM_DEPOTDOWNLOADER" <<'STUB'
#!/usr/bin/env bash
printf 'DepotDownloader %s\n' "$*" >> "$CALL_LOG"
dir=""; while [ $# -gt 0 ]; do [ "$1" = -dir ] && dir=$2; shift; done
case "${DD_MODE:-same}" in
  new) echo "build-2" > "$dir/valheim_server.x86_64" ;;
  fail) echo "partial" > "$dir/valheim_server.x86_64.tmp"; exit 1 ;;
  same) ;;
esac
STUB
# shellcheck disable=SC2016  # stub body is meant to be literal
printf '#!/usr/bin/env bash\nprintf "systemctl %%s\\n" "$*" >> "$CALL_LOG"\n' > "$tmp/bin/systemctl"
# Ubuntu has sha256sum; macOS test hosts only have shasum.
printf '#!/usr/bin/env bash\nshasum -a 256 "$@"\n' > "$tmp/bin/sha256sum"
chmod +x "$VALHEIM_DEPOTDOWNLOADER" "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

fail() { echo "FAIL: $1"; exit 1; }
reset() {
  : > "$CALL_LOG"; rm -rf "$VALHEIM_SERVER_DIR" "$VALHEIM_HOME/server.prev"; mkdir -p "$VALHEIM_SERVER_DIR"
  echo "build-1" > "$VALHEIM_SERVER_DIR/valheim_server.x86_64"; echo "cfg" > "$VALHEIM_SERVER_DIR/steam_appid.txt"
  unset DD_MODE
}
restart_count() { grep -c '^systemctl restart valheim' "$CALL_LOG" || true; }

restarts_only_when_binary_changes() {
  reset; export DD_MODE=new
  bash "$update" >/dev/null || fail "restarts_only_when_binary_changes: exit $?"
  [ "$(restart_count)" = 1 ] || fail "restarts_only_when_binary_changes: restart count $(restart_count)"
  [ "$(cat "$VALHEIM_HOME/server.prev/valheim_server.x86_64")" = build-1 ] || fail "restarts_only_when_binary_changes: server.prev not the old build"
  [ "$(cat "$VALHEIM_SERVER_DIR/valheim_server.x86_64")" = build-2 ] || fail "restarts_only_when_binary_changes: server not updated"
}
no_restart_when_unchanged() {
  reset; export DD_MODE=same
  bash "$update" >/dev/null || fail "no_restart_when_unchanged: exit $?"
  [ "$(restart_count)" = 0 ] || fail "no_restart_when_unchanged: restarted"
  grep -q '^DepotDownloader .*-app 896660 .*-dir ' "$CALL_LOG" || fail "no_restart_when_unchanged: DepotDownloader not invoked correctly: $(cat "$CALL_LOG")"
}
download_failure_keeps_prev_and_service() {
  reset; export DD_MODE=fail
  if bash "$update" >/dev/null 2>&1; then fail "download_failure_keeps_prev_and_service: exited 0"; fi
  [ "$(restart_count)" = 0 ] || fail "download_failure_keeps_prev_and_service: restarted"
  [ "$(cat "$VALHEIM_HOME/server.prev/valheim_server.x86_64")" = build-1 ] || fail "download_failure_keeps_prev_and_service: server.prev missing/wrong"
}
rollback_swaps_prev_back() {
  reset; export DD_MODE=new
  bash "$update" >/dev/null || fail "rollback_swaps_prev_back: update failed"
  : > "$CALL_LOG"
  bash "$rollback" >/dev/null || fail "rollback_swaps_prev_back: rollback exit $?"
  [ "$(cat "$VALHEIM_SERVER_DIR/valheim_server.x86_64")" = build-1 ] || fail "rollback_swaps_prev_back: server not restored"
  grep -q '^systemctl stop valheim' "$CALL_LOG" || fail "rollback_swaps_prev_back: no stop"
  grep -q '^systemctl start valheim' "$CALL_LOG" || fail "rollback_swaps_prev_back: no start"
}
rollback_refuses_without_prev() {
  reset
  if bash "$rollback" >/dev/null 2>&1; then fail "rollback_refuses_without_prev: exited 0"; fi
  [ "$(cat "$VALHEIM_SERVER_DIR/valheim_server.x86_64")" = build-1 ] || fail "rollback_refuses_without_prev: server touched"
}

for t in restarts_only_when_binary_changes no_restart_when_unchanged download_failure_keeps_prev_and_service rollback_swaps_prev_back rollback_refuses_without_prev; do
  "$t"; echo "ok $t"
done
echo PASS
