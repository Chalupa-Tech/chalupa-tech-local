#!/usr/bin/env bash
# Seed `secret/grafana/admin` (admin-user + admin-password), create the
# `observability-read` Vault policy granting `secret/data/grafana/*` reads,
# and bind that policy to the existing `external-secrets` Kubernetes auth role.
#
# Idempotent: re-running on a seeded cluster is a no-op (skips secret write if
# both fields exist; bao policy write is upsert; role rebind only happens if
# observability-read is missing from the role's policies list). Pass --force
# to regenerate the password.
#
# NOTE: an earlier version of this script appended `secret/data/grafana/*` to
# the policy *named* `external-secrets`, but that policy is NOT bound to the
# `external-secrets` Kubernetes auth role on this cluster — the role binds
# `cloudflare-read` + `media-read` per the established <tier>-read convention.
# The original approach silently produced 403s when ESO tried to read the
# grafana secret. The current script creates a properly-named tier policy and
# binds it to the role, matching the existing pattern.
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

# ---- Step 2: create observability-read policy ------------------------------
#
# `bao policy write` is upsert-style — running on each invocation is safe and
# converges on the desired contents.

OBS_POLICY_HCL='path "secret/data/grafana/*" { capabilities = ["read"] }'
echo "$OBS_POLICY_HCL" | bao_exec policy write observability-read - >/dev/null
echo "==> Wrote policy 'observability-read' (grants read on secret/data/grafana/*)"

# ---- Step 3: bind observability-read to the external-secrets role ----------
#
# Read the role's current config, check whether observability-read is already
# in the policies array, and if not, re-write the role with the merged list.
# All other role attributes (bound SAs, namespaces, ttl) are preserved.

ROLE_JSON=$(bao_exec read -format=json auth/kubernetes/role/external-secrets)

CURRENT_POLICIES=$(echo "$ROLE_JSON" | jq -r '.data.policies | join(",")')
BOUND_SA_NAMES=$(echo "$ROLE_JSON" | jq -r '.data.bound_service_account_names | join(",")')
BOUND_SA_NAMESPACES=$(echo "$ROLE_JSON" | jq -r '.data.bound_service_account_namespaces | join(",")')
TOKEN_TTL=$(echo "$ROLE_JSON" | jq -r '.data.token_ttl // 3600')

if echo ",$CURRENT_POLICIES," | grep -q ",observability-read,"; then
  echo "==> Role 'external-secrets' already binds observability-read. Skipping rebind."
else
  NEW_POLICIES="${CURRENT_POLICIES},observability-read"
  bao_exec write auth/kubernetes/role/external-secrets \
    bound_service_account_names="$BOUND_SA_NAMES" \
    bound_service_account_namespaces="$BOUND_SA_NAMESPACES" \
    policies="$NEW_POLICIES" \
    ttl="${TOKEN_TTL}s" >/dev/null
  echo "==> Bound observability-read to role 'external-secrets'."
  echo "    policies: $CURRENT_POLICIES → $NEW_POLICIES"
fi

# ---- Verification ----------------------------------------------------------

echo
echo "==> Verification:"

# Confirm secret has both fields:
bao_exec kv get -format=json secret/grafana/admin \
  | jq -r '.data.data | "    secret/grafana/admin: admin-user=" + ."admin-user" + ", admin-password=<" + (."admin-password" | length | tostring) + "-char redacted>"'

# Confirm policy contents:
bao_exec policy read observability-read \
  | sed 's/^/    policy observability-read: /'

# Confirm role binds the policy:
bao_exec read -format=json auth/kubernetes/role/external-secrets \
  | jq -r '.data.policies | "    role external-secrets: policies = [" + join(", ") + "]"'

echo
echo "==> Done. ESO can now read secret/grafana/admin via the openbao ClusterSecretStore."
echo "    If Grafana was already deployed and stuck waiting for the secret, the"
echo "    ExternalSecret should sync within ~1m. Force an immediate sync with:"
echo
echo "        kubectl -n grafana annotate externalsecret grafana-admin-creds \\"
echo "          force-sync=\$(date +%s) --overwrite"
