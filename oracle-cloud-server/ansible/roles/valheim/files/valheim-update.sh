#!/usr/bin/env bash
# Daily Valheim dedicated-server updater (systemd valheim-update.timer).
# Pulls the current Steam build with DepotDownloader into the server dir,
# keeping a full copy of the previous build in $VALHEIM_HOME/server.prev for
# valheim-rollback.sh, and restarts the service only if the binary changed.
#
# Paths come from /opt/valheim/update.env (templated by Ansible); env vars
# of the same name override it (tests).
set -euo pipefail

# shellcheck disable=SC1090  # path is configurable
[ -f "${VALHEIM_UPDATE_ENV:-/opt/valheim/update.env}" ] && . "${VALHEIM_UPDATE_ENV:-/opt/valheim/update.env}"
VALHEIM_HOME="${VALHEIM_HOME:-/opt/valheim}"
VALHEIM_SERVER_DIR="${VALHEIM_SERVER_DIR:-$VALHEIM_HOME/server}"
VALHEIM_DEPOTDOWNLOADER="${VALHEIM_DEPOTDOWNLOADER:?set in update.env}"
VALHEIM_APP_ID="${VALHEIM_APP_ID:-896660}"
prev="$VALHEIM_HOME/server.prev"
binary="$VALHEIM_SERVER_DIR/valheim_server.x86_64"

log() { printf '[valheim-update] %s\n' "$*"; }
checksum() { [ -f "$binary" ] && sha256sum "$binary" | cut -d' ' -f1 || echo none; }

before=$(checksum)
# Snapshot the running build first so a failed/partial download is always
# recoverable with valheim-rollback.sh.
rsync -a --delete --checksum "$VALHEIM_SERVER_DIR/" "$prev/"
log "previous build saved to $prev (sha256 $before)"

# The service runs as root (it must restart valheim); the download itself
# runs as the valheim user so file ownership stays correct.
run_dd() {
  if [ "$(id -u)" = 0 ] && [ -n "${VALHEIM_USER:-}" ]; then
    runuser -u "$VALHEIM_USER" -- "$VALHEIM_DEPOTDOWNLOADER" -app "$VALHEIM_APP_ID" -dir "$VALHEIM_SERVER_DIR"
  else
    "$VALHEIM_DEPOTDOWNLOADER" -app "$VALHEIM_APP_ID" -dir "$VALHEIM_SERVER_DIR"
  fi
}
if ! run_dd; then
  log "DepotDownloader failed; server.prev kept, service untouched" >&2
  exit 1
fi

after=$(checksum)
if [ "$before" = "$after" ]; then
  log "no change (sha256 $after)"
  exit 0
fi
log "binary changed ($before -> $after); restarting valheim"
systemctl restart valheim
