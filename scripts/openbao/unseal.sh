#!/usr/bin/env bash
# Unseal all OpenBao pods. Idempotent — pods already unsealed are skipped.
#
# Usage:
#   OPENBAO_KEY_1=... OPENBAO_KEY_2=... OPENBAO_KEY_3=... ./scripts/openbao/unseal.sh
#   ./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json
#
# Notes:
#   - Unseal keys are piped via stdin to `bao operator unseal -` so they do
#     not appear in any process's argv.
#   - If a pod is unreachable, the script logs a warning and moves on to
#     the next pod rather than halting.
#
# Requires: kubectl with KUBECONFIG set, jq (only if --keys-file).
set -euo pipefail

if [[ "${1:-}" == "--keys-file" ]]; then
  KEYS_FILE="${2:?--keys-file requires a path}"
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

  # bao status returns exit 0 when unsealed, exit 2 when sealed, exit 1 on error.
  # Capture stdout separately from exit so set -o pipefail doesn't mask exit 2.
  set +e
  status_json=$(kubectl -n "$NS" exec "$pod" -- bao status -format=json 2>/dev/null)
  kubectl_rc=$?
  set -e

  if [[ -z "$status_json" ]]; then
    # Empty output means kubectl exec itself failed (pod doesn't exist, not Ready, etc.)
    echo "    WARN: could not reach pod (kubectl exec rc=$kubectl_rc), skipping"
    continue
  fi

  sealed=$(printf '%s' "$status_json" | jq -r '.sealed' 2>/dev/null || echo "parse-error")
  initialized=$(printf '%s' "$status_json" | jq -r '.initialized' 2>/dev/null || echo "parse-error")

  if [[ "$initialized" != "true" ]]; then
    echo "    WARN: pod is not initialized (initialized=$initialized); run 'bao operator init' first, skipping"
    continue
  fi

  if [[ "$sealed" == "false" ]]; then
    echo "    already unsealed, skipping"
    continue
  fi

  if [[ "$sealed" != "true" ]]; then
    echo "    WARN: unexpected bao status output (sealed=$sealed), skipping"
    continue
  fi

  for key in "$OPENBAO_KEY_1" "$OPENBAO_KEY_2" "$OPENBAO_KEY_3"; do
    printf '%s\n' "$key" | kubectl -n "$NS" exec -i "$pod" -- bao operator unseal - >/dev/null
  done
  echo "    unsealed"
done
