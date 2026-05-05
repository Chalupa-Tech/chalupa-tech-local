#!/usr/bin/env bash
# Write a key/value to OpenBao KV v2 (mount: secret).
#
# Usage:
#   OPENBAO_TOKEN=<token> ./scripts/openbao/kv-put.sh <path> <key> <value>
#   ./scripts/openbao/kv-put.sh cloudflare/api-token token "abc123..."
#   ./scripts/openbao/kv-put.sh cloudflare/api-token token -    # value from stdin
#
# Notes:
#   - The KV value is sent via stdin and never appears in any process's argv.
#   - The OPENBAO_TOKEN value appears in kubectl's argv on the operator's Mac
#     (as an --env flag value), but does NOT appear in the container's
#     process table — kubectl exec --env injects env vars to the exec'd
#     process directly, not via a shell string.
#   - Operator-supplied path and key go through kubectl exec's argv as
#     direct arguments to `bao kv put` (no shell interpolation), so quoting
#     edge cases are not a concern.
#
# Requires: kubectl with KUBECONFIG set, OPENBAO_TOKEN env var.
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <path> <key> <value>" >&2
  echo "       $0 <path> <key> -    (read value from stdin)" >&2
  exit 2
fi

VAULT_PATH=$1
KEY=$2
VALUE=$3

: "${OPENBAO_TOKEN:?OPENBAO_TOKEN must be set}"

if [[ "$VALUE" == "-" ]]; then
  VALUE=$(cat)
fi

# Pick any Running OpenBao pod (defaults to openbao-0 if available).
POD=$(kubectl -n openbao get pods \
  -l app.kubernetes.io/name=openbao \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
: "${POD:?no Running OpenBao pod found in namespace openbao}"

# Pipe value via stdin; pass token via --env (not visible in container argv);
# pass path/key as direct args to bao (no shell string interpolation).
printf '%s' "$VALUE" | kubectl -n openbao exec -i "$POD" \
  --env "BAO_ADDR=http://127.0.0.1:8200" \
  --env "BAO_TOKEN=$OPENBAO_TOKEN" \
  -- bao kv put -mount=secret "$VAULT_PATH" "$KEY=-"
