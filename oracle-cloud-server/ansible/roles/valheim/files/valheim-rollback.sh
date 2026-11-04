#!/usr/bin/env bash
# Roll the Valheim server back to the build saved by valheim-update.sh
# (server.prev). Run as root: sudo /opt/valheim/valheim-rollback.sh
set -euo pipefail

# shellcheck disable=SC1090  # path is configurable
[ -f "${VALHEIM_UPDATE_ENV:-/opt/valheim/update.env}" ] && . "${VALHEIM_UPDATE_ENV:-/opt/valheim/update.env}"
VALHEIM_HOME="${VALHEIM_HOME:-/opt/valheim}"
VALHEIM_SERVER_DIR="${VALHEIM_SERVER_DIR:-$VALHEIM_HOME/server}"
prev="$VALHEIM_HOME/server.prev"

if [ ! -f "$prev/valheim_server.x86_64" ]; then
  echo "[valheim-rollback] no previous build at $prev — nothing to roll back to" >&2
  exit 1
fi
echo "[valheim-rollback] stopping valheim, restoring $prev -> $VALHEIM_SERVER_DIR"
systemctl stop valheim
rsync -a --delete --checksum "$prev/" "$VALHEIM_SERVER_DIR/"
systemctl start valheim
echo "[valheim-rollback] done"
