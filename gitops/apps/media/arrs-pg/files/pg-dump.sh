#!/usr/bin/env bash
# Nightly logical dump of the arrs-pg CNPG cluster (CronJob arrs-pg-dump).
# pg_dumpall over the rw service as the superuser, zstd-compressed onto the
# backups NFS volume, verified with `zstd -t`, pruned to KEEP newest.
#
# Env (from the CronJob): PGHOST, PGUSER, PGPASSWORD (via Secret, never on
# the command line or in logs), OUT_DIR (default /backups/postgres), KEEP (14).
set -euo pipefail

OUT_DIR="${OUT_DIR:-/backups/postgres}"
KEEP="${KEEP:-14}"
# A real dump of arrs-pg is megabytes; anything under MIN_BYTES is treated as a failed dump.
MIN_BYTES="${MIN_BYTES:-1024}"
: "${PGHOST:?PGHOST required}"
: "${PGUSER:?PGUSER required}"
: "${PGPASSWORD:?PGPASSWORD required}"
export PGPASSWORD

mkdir -p "$OUT_DIR"
stamp=$(date -u +%Y%m%d-%H%M)
out="$OUT_DIR/arrs-pg-$stamp.sql.zst"
tmp="$out.partial"
log() { printf '[pg-dump] %s\n' "$*"; }
cleanup_partial() { rm -f "$tmp"; }
trap cleanup_partial EXIT

log "dumping all databases from $PGHOST as $PGUSER -> $out"
if ! pg_dumpall -h "$PGHOST" -U "$PGUSER" --no-password | zstd -q -T0 -o "$tmp"; then
  log "pg_dumpall failed; no archive written" >&2
  exit 1
fi
zstd -t -q "$tmp"
size=$(stat -c %s "$tmp" 2>/dev/null || stat -f %z "$tmp")
[ "$size" -ge "$MIN_BYTES" ] || { log "archive suspiciously small ($size bytes < $MIN_BYTES)" >&2; exit 1; }
mv -f "$tmp" "$out"
log "verified $out ($size bytes)"

# Prune: keep the KEEP newest archives.
# Archive names carry a UTC timestamp, so a reverse name sort is newest-first.
find "$OUT_DIR" -maxdepth 1 -name 'arrs-pg-*.sql.zst' | sort -r | tail -n +$((KEEP + 1)) | while IFS= read -r f; do
  rm -f -- "$f"
  log "pruned $f"
done
log "done; $(find "$OUT_DIR" -maxdepth 1 -name 'arrs-pg-*.sql.zst' | wc -l | tr -d ' ') archive(s) kept"
