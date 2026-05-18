#!/usr/bin/env bash
# Apply an OpenBao policy from scripts/openbao/policies/<name>.hcl to the
# live cluster. The .hcl file is the source of truth; this script just
# pipes it into `bao policy write`.
#
# Usage:
#   OPENBAO_TOKEN=<token> ./scripts/openbao/apply-policy.sh <policy-name>
#
# Example:
#   OPENBAO_TOKEN=$(jq -r '.root_token' ~/secure/openbao-init.json) \
#     ./scripts/openbao/apply-policy.sh media-read
#
# After apply, verify drift with:
#   kubectl -n openbao exec openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 \
#     BAO_TOKEN="$OPENBAO_TOKEN" bao policy read <policy-name>
#
# Requires: kubectl with KUBECONFIG set, OPENBAO_TOKEN env var.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <policy-name>" >&2
  echo "       Reads scripts/openbao/policies/<policy-name>.hcl and applies it" >&2
  exit 2
fi

POLICY_NAME=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
POLICY_FILE="$SCRIPT_DIR/policies/$POLICY_NAME.hcl"

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "Policy file not found: $POLICY_FILE" >&2
  exit 1
fi

: "${OPENBAO_TOKEN:?OPENBAO_TOKEN must be set}"

POD=$(kubectl -n openbao get pods \
  -l app.kubernetes.io/name=openbao \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
: "${POD:?no Running OpenBao pod found in namespace openbao}"

# Pipe the .hcl via stdin so the file contents never appear in any argv.
# Token flows via env (see kv-put.sh for the same pattern + rationale).
kubectl -n openbao exec -i "$POD" \
  -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$OPENBAO_TOKEN" \
    bao policy write "$POLICY_NAME" - < "$POLICY_FILE"
