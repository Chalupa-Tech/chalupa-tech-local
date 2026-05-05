#!/usr/bin/env bash
# Write a key/value to OpenBao KV v2 (mount: secret).
#
# Usage:
#   OPENBAO_TOKEN=<token> ./scripts/openbao/kv-put.sh <path> <key> <value>
#   ./scripts/openbao/kv-put.sh cloudflare/api-token token "abc123..."
#   ./scripts/openbao/kv-put.sh cloudflare/api-token token -    # value from stdin
#
# Requires: kubectl with KUBECONFIG set, OPENBAO_TOKEN env var.
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <path> <key> <value>" >&2
  echo "       $0 <path> <key> -    (read value from stdin)" >&2
  exit 2
fi

PATH_=$1
KEY=$2
VALUE=$3

: "${OPENBAO_TOKEN:?OPENBAO_TOKEN must be set}"

if [[ "$VALUE" == "-" ]]; then
  VALUE=$(cat)
fi

# Send value via stdin to avoid leaking through process args.
printf '%s' "$VALUE" | kubectl -n openbao exec -i openbao-0 -- sh -c "
  export BAO_ADDR=http://127.0.0.1:8200
  export BAO_TOKEN='$OPENBAO_TOKEN'
  bao kv put -mount=secret '$PATH_' '$KEY=-'
"
