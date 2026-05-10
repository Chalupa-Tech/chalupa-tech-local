#!/usr/bin/env bash
# Seed `secret/grafana/admin` (admin-user + admin-password) and extend the
# `external-secrets` Vault policy to read `secret/data/grafana/*`.
#
# Idempotent: re-running on an already-seeded cluster is a no-op (skips secret
# write if the secret exists with both fields, skips policy write if the line
# is already present). Pass --force to regenerate the password and overwrite.
#
# Usage:
#   ./scripts/openbao/seed-grafana-admin.sh                      # default: ~/secure/openbao-init.json
#   ./scripts/openbao/seed-grafana-admin.sh --keys-file PATH     # custom path
#   ./scripts/openbao/seed-grafana-admin.sh --force              # regenerate password + overwrite
#
# Outputs the new password ONCE to stdout when generated. Save it in 1Password
# (or your password manager). After that, the password lives only in OpenBao.
#
# Security:
#   - admin-password value is sent to bao via JSON on stdin; never appears in
#     any process's argv.
#   - Root token appears in kubectl's argv on this Mac (briefly, as an `env`
#     argument value), but does NOT appear in `bao`'s argv inside the
#     container — `env KEY=VAL bao ...` runs `env`, which sets the environment
#     and execs `bao`. /proc/<bao-pid>/cmdline does not contain the token.
#   - The keys file (~/secure/openbao-init.json) should live encrypted at rest.
#
# Requires: kubectl with KUBECONFIG set, jq, openssl.
set -euo pipefail

# ---- Defaults / arg parsing -------------------------------------------------

KEYS_FILE="${HOME}/secure/openbao-init.json"
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keys-file)
      KEYS_FILE="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ---- Prereqs ---------------------------------------------------------------

for tool in kubectl jq openssl; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: '$tool' not found in PATH. Install via: brew install $tool" >&2
    exit 1
  }
done

: "${KUBECONFIG:?KUBECONFIG must be set. Pull from pulumi-talos: pulumi stack output kubeconfig --show-secrets > ~/.kube/chalupa-cluster.yaml; export KUBECONFIG=~/.kube/chalupa-cluster.yaml}"

if [[ ! -r "$KEYS_FILE" ]]; then
  echo "ERROR: keys file not readable: $KEYS_FILE" >&2
  echo "Pass --keys-file PATH if it lives elsewhere." >&2
  exit 1
fi

ROOT_TOKEN=$(jq -r '.root_token // empty' "$KEYS_FILE")
if [[ -z "$ROOT_TOKEN" ]]; then
  echo "ERROR: .root_token not found in $KEYS_FILE" >&2
  exit 1
fi

# ---- Pick a Running OpenBao pod --------------------------------------------

POD=$(kubectl -n openbao get pods \
  -l app.kubernetes.io/name=openbao \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
: "${POD:?no Running OpenBao pod found in namespace openbao. Run ./scripts/openbao/unseal.sh first if pods are sealed.}"

# Helper: run `bao` inside the chosen pod with the root token via env.
bao_exec() {
  kubectl -n openbao exec -i "$POD" \
    -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$ROOT_TOKEN" \
    bao "$@"
}

# Sanity check: confirm OpenBao is unsealed and the token works.
if ! bao_exec status -format=json | jq -e '.sealed == false' >/dev/null; then
  echo "ERROR: OpenBao pod $POD is sealed. Run ./scripts/openbao/unseal.sh first." >&2
  exit 1
fi

if ! bao_exec token lookup -format=json >/dev/null 2>&1; then
  echo "ERROR: root token from $KEYS_FILE is invalid or rejected by OpenBao." >&2
  exit 1
fi

echo "==> OpenBao reachable. Pod: $POD"

# ---- Step 1: seed secret/grafana/admin --------------------------------------

NEED_WRITE=1
if bao_exec kv get -format=json secret/grafana/admin >/dev/null 2>&1; then
  HAS_BOTH=$(bao_exec kv get -format=json secret/grafana/admin \
    | jq -r 'if (.data.data."admin-user" != null and .data.data."admin-password" != null) then "yes" else "no" end')
  if [[ "$HAS_BOTH" == "yes" && "$FORCE" -ne 1 ]]; then
    NEED_WRITE=0
    echo "==> secret/grafana/admin already has both fields. Skipping write (use --force to regenerate)."
  fi
fi

if [[ "$NEED_WRITE" -eq 1 ]]; then
  GRAFANA_PASS=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)

  # Send both fields as JSON via stdin so the password never lands in argv.
  printf '{"admin-user":"admin","admin-password":"%s"}' "$GRAFANA_PASS" \
    | bao_exec kv put -format=json secret/grafana/admin - >/dev/null

  echo "==> Wrote secret/grafana/admin (admin-user=admin, admin-password=<new>)"
  echo
  echo "  ┌─────────────────────────────────────────────────────────────────┐"
  echo "  │ SAVE THIS PASSWORD IN 1PASSWORD NOW. It is shown only once.    │"
  echo "  │                                                                 │"
  printf "  │   admin-password: %-44s │\n" "$GRAFANA_PASS"
  echo "  │                                                                 │"
  echo "  │ Suggested 1Password entry: 'homelab-grafana-admin'              │"
  echo "  └─────────────────────────────────────────────────────────────────┘"
  echo
  unset GRAFANA_PASS
fi

# ---- Step 2: extend external-secrets policy --------------------------------

POLICY_TMP=$(mktemp -t eso-policy.XXXXXX.hcl)
trap 'rm -f "$POLICY_TMP"' EXIT

if ! bao_exec policy read external-secrets > "$POLICY_TMP" 2>/dev/null; then
  echo "ERROR: failed to read external-secrets policy. Was it created in sub-project #2?" >&2
  exit 1
fi

if grep -qE 'path "secret/data/grafana/\*"' "$POLICY_TMP"; then
  echo "==> external-secrets policy already grants secret/data/grafana/*. Skipping."
else
  printf '\npath "secret/data/grafana/*" { capabilities = ["read"] }\n' >> "$POLICY_TMP"
  bao_exec policy write external-secrets - < "$POLICY_TMP"
  echo "==> Extended external-secrets policy: + secret/data/grafana/* (read)"
fi

# ---- Verification ----------------------------------------------------------

echo
echo "==> Verification:"

# Confirm secret has both fields:
bao_exec kv get -format=json secret/grafana/admin \
  | jq -r '.data.data | "    admin-user: " + ."admin-user" + "    admin-password: <" + (."admin-password" | length | tostring) + "-char redacted>"'

# Confirm policy includes the grafana line:
bao_exec policy read external-secrets \
  | grep -E 'path "secret/data/grafana/\*"' \
  | sed 's/^/    /'

echo
echo "==> Done. Sub-project #5 Task 7 complete."
echo "    (Grafana wrapper PR — Task 8 — can now be opened.)"
