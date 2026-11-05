#!/usr/bin/env bash
# Unit tests for files/valheim-update.sh and files/valheim-rollback.sh with
# stubbed DepotDownloader/systemctl/runuser; real rsync.
#
# Update flow under test: copy server -> server.new (staging), download into
# staging, compare the build fingerprint (stub binary + assembly dll); if
# changed: rotate server -> server.prev, staging -> server, restart; if not:
# drop staging, leave server.prev alone. A failed download leaves server and
# server.prev untouched and never restarts. A hold file pauses updates.
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
export VALHEIM_USER=""   # non-root test run: no runuser

# DepotDownloader stub: DD_MODE=same|new-dll|fail. Patches change the Unity
# assembly, not the stub binary — exactly the case the fingerprint must catch.
cat > "$VALHEIM_DEPOTDOWNLOADER" <<'STUB'
#!/usr/bin/env bash
printf 'DepotDownloader %s\n' "$*" >> "$CALL_LOG"
dir=""; while [ $# -gt 0 ]; do [ "$1" = -dir ] && dir=$2; shift; done
case "${DD_MODE:-same}" in
  new-dll) echo "assembly-2" > "$dir/valheim_server_Data/Managed/assembly_valheim.dll" ;;
  fail) echo "partial" > "$dir/valheim_server_Data/Managed/assembly_valheim.dll"; exit 1 ;;
  same) ;;
esac
STUB
# shellcheck disable=SC2016  # stub bodies are meant to be literal
printf '#!/usr/bin/env bash\nprintf "systemctl %%s\\n" "$*" >> "$CALL_LOG"\n' > "$tmp/bin/systemctl"
printf '#!/usr/bin/env bash\nshasum -a 256 "$@"\n' > "$tmp/bin/sha256sum"
chmod +x "$VALHEIM_DEPOTDOWNLOADER" "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

fail() { echo "FAIL: $1"; exit 1; }
seed() { # <dir> <assembly content>
  mkdir -p "$1/valheim_server_Data/Managed"
  echo "unity-stub" > "$1/valheim_server.x86_64"; echo "$2" > "$1/valheim_server_Data/Managed/assembly_valheim.dll"; echo "cfg" > "$1/steam_appid.txt"
}
reset() {
  : > "$CALL_LOG"; rm -rf "$VALHEIM_SERVER_DIR" "$VALHEIM_HOME/server.prev" "$VALHEIM_HOME/server.new" "$VALHEIM_HOME/update.hold"
  seed "$VALHEIM_SERVER_DIR" assembly-1; unset DD_MODE
}
restart_count() { grep -c '^systemctl restart valheim' "$CALL_LOG" || true; }
dll() { cat "$1/valheim_server_Data/Managed/assembly_valheim.dll"; }

restarts_when_assembly_changes() {
  reset; export DD_MODE=new-dll
  bash "$update" >/dev/null || fail "restarts_when_assembly_changes: exit $?"
  [ "$(restart_count)" = 1 ] || fail "restarts_when_assembly_changes: restart count $(restart_count)"
  [ "$(dll "$VALHEIM_SERVER_DIR")" = assembly-2 ] || fail "restarts_when_assembly_changes: server not updated"
  [ "$(dll "$VALHEIM_HOME/server.prev")" = assembly-1 ] || fail "restarts_when_assembly_changes: server.prev is not the old build"
  [ ! -d "$VALHEIM_HOME/server.new" ] || fail "restarts_when_assembly_changes: staging left behind"
}
no_restart_and_prev_untouched_when_unchanged() {
  reset; mkdir -p "$VALHEIM_HOME/server.prev"; seed "$VALHEIM_HOME/server.prev" assembly-0; export DD_MODE=same
  bash "$update" >/dev/null || fail "unchanged: exit $?"
  [ "$(restart_count)" = 0 ] || fail "unchanged: restarted"
  [ "$(dll "$VALHEIM_HOME/server.prev")" = assembly-0 ] || fail "unchanged: server.prev was overwritten (rollback window lost)"
  grep -q '^DepotDownloader .*-app 896660 .*-dir ' "$CALL_LOG" || fail "unchanged: DepotDownloader not invoked: $(cat "$CALL_LOG")"
  grep -q -- "-dir $VALHEIM_HOME/server.new" "$CALL_LOG" || fail "unchanged: download did not go to staging: $(cat "$CALL_LOG")"
}
download_failure_touches_nothing() {
  reset; mkdir -p "$VALHEIM_HOME/server.prev"; seed "$VALHEIM_HOME/server.prev" assembly-0; export DD_MODE=fail
  if bash "$update" >/dev/null 2>&1; then fail "download_failure: exited 0"; fi
  [ "$(restart_count)" = 0 ] || fail "download_failure: restarted"
  [ "$(dll "$VALHEIM_SERVER_DIR")" = assembly-1 ] || fail "download_failure: live server dir was modified"
  [ "$(dll "$VALHEIM_HOME/server.prev")" = assembly-0 ] || fail "download_failure: server.prev was modified"
  [ ! -d "$VALHEIM_HOME/server.new" ] || fail "download_failure: staging left behind"
}
rollback_swaps_prev_back_and_holds() {
  reset; export DD_MODE=new-dll
  bash "$update" >/dev/null || fail "rollback: update failed"
  : > "$CALL_LOG"
  bash "$rollback" >/dev/null || fail "rollback: exit $?"
  [ "$(dll "$VALHEIM_SERVER_DIR")" = assembly-1 ] || fail "rollback: server not restored"
  grep -q '^systemctl stop valheim' "$CALL_LOG" || fail "rollback: no stop"
  grep -q '^systemctl start valheim' "$CALL_LOG" || fail "rollback: no start"
  [ -f "$VALHEIM_HOME/update.hold" ] || fail "rollback: no hold file (next timer run would re-download the bad build)"
  : > "$CALL_LOG"; export DD_MODE=new-dll
  bash "$update" >/dev/null || fail "rollback: held update exited non-zero"
  ! grep -q DepotDownloader "$CALL_LOG" || fail "rollback: update ran while held"
}
rollback_refuses_without_prev() {
  reset
  if bash "$rollback" >/dev/null 2>&1; then fail "rollback_refuses_without_prev: exited 0"; fi
  [ "$(dll "$VALHEIM_SERVER_DIR")" = assembly-1 ] || fail "rollback_refuses_without_prev: server touched"
}
runs_download_as_valheim_user_with_home() {
  reset; export VALHEIM_USER=valheim DD_MODE=same
  # fake root: the script decides on `id -u`; stub it and runuser
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n[ "$1" = -u ] && echo 0 || command id "$@"\n' > "$tmp/bin/id"
  cat > "$tmp/bin/runuser" <<'STUB'
#!/usr/bin/env bash
printf 'runuser %s\n' "$*" >> "$CALL_LOG"
# runuser -u <user> -- <cmd...>
shift 3; exec "$@"
STUB
  chmod +x "$tmp/bin/id" "$tmp/bin/runuser"
  bash "$update" >/dev/null || fail "runuser: exit $?"
  grep -q "^runuser -u valheim -- env HOME=$VALHEIM_HOME " "$CALL_LOG" || fail "runuser: HOME not set for the valheim user: $(grep runuser "$CALL_LOG" || true)"
  rm -f "$tmp/bin/id" "$tmp/bin/runuser"; export VALHEIM_USER=""
}

for t in restarts_when_assembly_changes no_restart_and_prev_untouched_when_unchanged download_failure_touches_nothing rollback_swaps_prev_back_and_holds rollback_refuses_without_prev runs_download_as_valheim_user_with_home; do
  "$t"; echo "ok $t"
done
echo PASS
