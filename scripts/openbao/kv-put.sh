#!/usr/bin/env bash
# Write one or more key/value pairs to an OpenBao KV v2 secret (mount: secret).
#
# Usage:
#   OPENBAO_TOKEN=<token> ./scripts/openbao/kv-put.sh <path> <key>=<value> [<key>=<value> ...]
#
# Value forms (per pair):
#   key=value         literal value
#   key=@/path/file   read the value from a local file (e.g. a PEM private key)
#   key=-             read the value from stdin (at most one key may use -)
#
# Examples:
#   ./scripts/openbao/kv-put.sh cloudflare/api-token token=abc123
#   ./scripts/openbao/kv-put.sh renovate/github-app appId=12345 installationId=67890 privateKey=@app.pem
#   cat app.pem | ./scripts/openbao/kv-put.sh renovate/github-app appId=12345 installationId=67890 privateKey=-
#
# Legacy form (still supported, single key, value via 3rd arg or stdin):
#   ./scripts/openbao/kv-put.sh <path> <key> <value>
#   ./scripts/openbao/kv-put.sh <path> <key> -
#
# Notes:
#   - All KV values are assembled into one JSON object and sent via stdin; no
#     value ever appears in any process's argv (neither on the Mac nor inside
#     the pod). `bao kv put ... -` reads that JSON from stdin.
#   - The OPENBAO_TOKEN value appears in kubectl's argv on the operator's Mac
#     (as an argument to `env`), but does NOT appear in `bao`'s argv inside the
#     container — `env KEY=VALUE bao ...` runs `env`, which sets the environment
#     then exec's `bao`, so `bao`'s /proc/<pid>/cmdline doesn't contain it.
#   - This is a KV v2 `put`, which REPLACES the secret's data. Pass every key
#     the secret should contain in a single call (this is why multi-key matters:
#     three separate puts would clobber down to the last key).
#   - Operator-supplied path goes through kubectl exec's argv as a direct
#     argument to `bao kv put` (no shell interpolation).
#
# Requires: kubectl with KUBECONFIG set, python3, OPENBAO_TOKEN env var.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <path> <key>=<value> [<key>=<value> ...]" >&2
  echo "       $0 <path> <key> <value>           (legacy single-key form)" >&2
  echo "       value forms: key=value | key=@file | key=-  (stdin)" >&2
  exit 2
fi

VAULT_PATH=$1
shift

# Legacy form: exactly `<key> <value>` with a bare key (no '='). Fold it into
# the new key=value parser so there is a single code path below.
if [[ $# -eq 2 && "$1" != *=* ]]; then
  set -- "$1=$2"
fi

: "${OPENBAO_TOKEN:?OPENBAO_TOKEN must be set}"

declare -a KEYS VALS
stdin_used=0
for pair in "$@"; do
  if [[ "$pair" != *=* ]]; then
    echo "invalid argument (expected key=value): $pair" >&2
    exit 2
  fi
  key=${pair%%=*}
  val=${pair#*=}
  if [[ -z "$key" ]]; then
    echo "empty key in: $pair" >&2
    exit 2
  fi
  case "$val" in
    -)
      if [[ $stdin_used -ne 0 ]]; then
        echo "only one key may read its value from stdin (-)" >&2
        exit 2
      fi
      val=$(cat)
      stdin_used=1
      ;;
    @*)
      file=${val#@}
      if [[ ! -r "$file" ]]; then
        echo "cannot read file for $key: $file" >&2
        exit 2
      fi
      val=$(cat "$file")
      ;;
  esac
  KEYS+=("$key")
  VALS+=("$val")
done

# Assemble the JSON object on the Mac (keys/values via a NUL-delimited pipe, not
# argv) and hand it to bao over stdin. python3 handles all JSON escaping,
# including multi-line PEM values.
JSON=$(
  for i in "${!KEYS[@]}"; do
    printf '%s\0%s\0' "${KEYS[$i]}" "${VALS[$i]}"
  done | python3 -c '
import sys, json
parts = sys.stdin.buffer.read().split(b"\0")[:-1]
obj = {}
it = iter(parts)
for k in it:
    obj[k.decode()] = next(it).decode()
json.dump(obj, sys.stdout)
'
)

# Pick any Running OpenBao pod (defaults to openbao-0 if available).
POD=$(kubectl -n openbao get pods \
  -l app.kubernetes.io/name=openbao \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
: "${POD:?no Running OpenBao pod found in namespace openbao}"

# Pipe the JSON object via stdin; pass the token via `env` (kubectl exec has no
# --env flag). `bao kv put -mount=secret <path> -` reads the data as JSON from
# stdin and (KV v2) wraps it under data/ automatically.
printf '%s' "$JSON" | kubectl -n openbao exec -i "$POD" \
  -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$OPENBAO_TOKEN" \
    bao kv put -mount=secret "$VAULT_PATH" -
