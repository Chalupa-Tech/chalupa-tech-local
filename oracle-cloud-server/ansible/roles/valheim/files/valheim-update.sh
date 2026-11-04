#!/usr/bin/env bash
# Daily Valheim dedicated-server updater (systemd valheim-update.timer).
#
# Flow: copy the live server dir to a staging dir (server.new), let
# DepotDownloader update the staging copy, fingerprint both (the Unity stub
# binary AND assembly_valheim.dll — Valheim patches only change the latter).
#   unchanged  -> drop staging; server.prev is left alone
#   changed    -> server -> server.prev, staging -> server, restart valheim
#   failed     -> drop staging; live server and server.prev untouched
# A hold file ($VALHEIM_HOME/update.hold, written by valheim-rollback.sh)
# pauses updates until removed.
#
# Paths come from /opt/valheim/update.env (templated by Ansible); any
# variable already in the environment wins (tests).
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
VALHEIM_DEPOTDOWNLOADER="${VALHEIM_DEPOTDOWNLOADER:?set in update.env}"
VALHEIM_APP_ID="${VALHEIM_APP_ID:-896660}"
VALHEIM_USER="${VALHEIM_USER:-}"
prev="$VALHEIM_HOME/server.prev"
staging="$VALHEIM_HOME/server.new"
hold="$VALHEIM_HOME/update.hold"

log() { printf '[valheim-update] %s\n' "$*"; }

if [ -f "$hold" ]; then
  log "held: $hold exists (written by valheim-rollback.sh); remove it to resume updates"
  exit 0
fi

# Fingerprint = sha256 over the files a Steam patch actually changes.
fingerprint() {
  local d=$1 f
  for f in valheim_server.x86_64 valheim_server_Data/Managed/assembly_valheim.dll; do
    if [ -f "$d/$f" ]; then sha256sum "$d/$f" | cut -d' ' -f1; else echo missing; fi
  done | sha256sum | cut -d' ' -f1
}

cleanup() { rm -rf "$staging"; }
trap cleanup EXIT

rm -rf "$staging"
rsync -a "$VALHEIM_SERVER_DIR/" "$staging/"
before=$(fingerprint "$staging")

# The unit runs as root (it must restart valheim); the download runs as the
# valheim user with HOME pointed at its home so DepotDownloader's .NET
# runtime can write its caches.
run_dd() {
  if [ "$(id -u)" = 0 ] && [ -n "$VALHEIM_USER" ]; then
    runuser -u "$VALHEIM_USER" -- env HOME="$VALHEIM_HOME" "$VALHEIM_DEPOTDOWNLOADER" -app "$VALHEIM_APP_ID" -dir "$staging"
  else
    "$VALHEIM_DEPOTDOWNLOADER" -app "$VALHEIM_APP_ID" -dir "$staging"
  fi
}
if ! run_dd; then
  log "DepotDownloader failed; live server and server.prev untouched" >&2
  exit 1
fi

after=$(fingerprint "$staging")
if [ "$before" = "$after" ]; then
  log "no change (fingerprint $after)"
  exit 0
fi

log "build changed ($before -> $after); rotating server -> server.prev and restarting"
rm -rf "$prev"
mv "$VALHEIM_SERVER_DIR" "$prev"
mv "$staging" "$VALHEIM_SERVER_DIR"
systemctl restart valheim
log "done"
