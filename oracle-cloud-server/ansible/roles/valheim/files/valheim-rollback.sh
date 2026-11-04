#!/usr/bin/env bash
# Roll the Valheim server back to the build saved by valheim-update.sh
# (server.prev) and pause further automatic updates (update.hold). Run as
# root: sudo /opt/valheim/valheim-rollback.sh   — remove the hold file to
# resume: sudo rm /opt/valheim/update.hold
set -euo pipefail

env_file="${VALHEIM_UPDATE_ENV:-/opt/valheim/update.env}"
if [ -f "$env_file" ]; then
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    [ -n "${!k:-}" ] || export "$k=$v"
  done < "$env_file"
fi
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
date -u +"rolled back %Y-%m-%dT%H:%M:%SZ" > "$VALHEIM_HOME/update.hold"
systemctl start valheim
echo "[valheim-rollback] done; automatic updates are held until $VALHEIM_HOME/update.hold is removed"
