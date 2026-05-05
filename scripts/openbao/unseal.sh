#!/usr/bin/env bash
# Unseal all OpenBao pods. Idempotent — pods already unsealed are skipped.
#
# Usage:
#   OPENBAO_KEY_1=... OPENBAO_KEY_2=... OPENBAO_KEY_3=... ./scripts/openbao/unseal.sh
#   ./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json
#
# Requires: kubectl with KUBECONFIG set, jq (only if --keys-file).
set -euo pipefail

if [[ "${1:-}" == "--keys-file" ]]; then
  KEYS_FILE=$2
  : "${KEYS_FILE:?--keys-file requires a path}"
  OPENBAO_KEY_1=$(jq -r '.unseal_keys_b64[0]' "$KEYS_FILE")
  OPENBAO_KEY_2=$(jq -r '.unseal_keys_b64[1]' "$KEYS_FILE")
  OPENBAO_KEY_3=$(jq -r '.unseal_keys_b64[2]' "$KEYS_FILE")
fi

: "${OPENBAO_KEY_1:?OPENBAO_KEY_1 not set}"
: "${OPENBAO_KEY_2:?OPENBAO_KEY_2 not set}"
: "${OPENBAO_KEY_3:?OPENBAO_KEY_3 not set}"

NS=openbao
PODS=(openbao-0 openbao-1 openbao-2)

for pod in "${PODS[@]}"; do
  echo "==> $pod"
  sealed=$(kubectl -n "$NS" exec "$pod" -- bao status -format=json 2>/dev/null | jq -r '.sealed' || echo "unknown")
  if [[ "$sealed" == "false" ]]; then
    echo "    already unsealed, skipping"
    continue
  fi
  for key in "$OPENBAO_KEY_1" "$OPENBAO_KEY_2" "$OPENBAO_KEY_3"; do
    kubectl -n "$NS" exec "$pod" -- bao operator unseal "$key" >/dev/null
  done
  echo "    unsealed"
done
