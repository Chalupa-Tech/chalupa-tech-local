#!/bin/sh
# Hourly OpenBao raft snapshot (CronJob openbao-snapshot). POSIX sh: the
# OpenBao server image (used for the job) has neither bash nor jq.
#
# Logs in with the pod's Kubernetes service-account token (auth role
# openbao-snapshot, policy `snapshot`), saves a raft snapshot onto the
# backups NFS volume, verifies the archive (gzip tar of meta.json, state.bin
# and SHA256SUMS: `sha256sum -c` must pass — OpenBao's CLI has no `snapshot
# inspect` subcommand), prunes to KEEP newest. A sealed OpenBao cannot be snapshotted: fail loudly,
# write nothing. The login token lives in BAO_TOKEN only and is never printed.
set -eu

OUT_DIR="${OUT_DIR:-/backups/openbao}"
KEEP="${KEEP:-48}"
SA_TOKEN_FILE="${SA_TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}"
: "${BAO_ADDR:?BAO_ADDR required}"
export BAO_ADDR

log() { printf '[raft-snapshot] %s\n' "$*"; }

# `bao status` exit codes: 0 unsealed, 2 sealed, 1 error.
set +e
bao status -format=json >/dev/null 2>&1
status_rc=$?
set -e
case "$status_rc" in
  0) ;;
  2) log "OpenBao is sealed; cannot snapshot" >&2; exit 1 ;;
  *) log "cannot read OpenBao status at $BAO_ADDR (rc=$status_rc)" >&2; exit 1 ;;
esac

BAO_TOKEN=$(bao write -field=token auth/kubernetes/login role=openbao-snapshot jwt="$(cat "$SA_TOKEN_FILE")")
export BAO_TOKEN
[ -n "$BAO_TOKEN" ] || { log "Kubernetes auth login returned no token" >&2; exit 1; }

mkdir -p "$OUT_DIR"
stamp=$(date -u +%Y%m%d%H%M)
out="$OUT_DIR/raft-$stamp.snap"
tmp="$out.partial"
trap 'rm -f "$tmp"' EXIT

bao operator raft snapshot save "$tmp"
size=$(stat -c %s "$tmp" 2>/dev/null || stat -f %z "$tmp")
[ "$size" -gt 0 ] || { log "snapshot is empty" >&2; exit 1; }
# Verify: the snapshot is a tar.gz carrying SHA256SUMS over meta.json and
# state.bin. Unpack to a scratch dir and check the sums.
vdir=$(mktemp -d)
if ! tar -xzf "$tmp" -C "$vdir" meta.json state.bin SHA256SUMS 2>/dev/null \
   || ! (cd "$vdir" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
  rm -rf "$vdir"
  log "snapshot verification failed (sha256 mismatch or incomplete archive); discarding $tmp" >&2
  exit 1
fi
rm -rf "$vdir"
mv -f "$tmp" "$out"
log "saved $out ($size bytes, sha256 verified)"

# Names carry a UTC timestamp: reverse name sort is newest-first.
find "$OUT_DIR" -maxdepth 1 -name 'raft-*.snap' | sort -r | tail -n +$((KEEP + 1)) | while IFS= read -r f; do
  rm -f -- "$f"
  log "pruned $f"
done
log "done; $(find "$OUT_DIR" -maxdepth 1 -name 'raft-*.snap' | wc -l | tr -d ' ') snapshot(s) kept"
