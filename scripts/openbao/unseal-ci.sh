#!/usr/bin/env bash
# Unseal any sealed OpenBao replica from CI using key shares in the
# OPENBAO_UNSEAL_KEYS environment variable (newline- or comma-separated;
# 3 of the 5 Shamir shares). If the variable is absent the script prints a
# notice and exits 0 so callers can treat unsealing as opt-in (spec §8).
#
# Keys are never echoed: no `set -x`, and each share is passed to `bao` on
# its command line inside the pod only (kubectl exec does not log args).
# Requires KUBECONFIG. Companion to scripts/openbao/unseal.sh (workstation).
set -euo pipefail
set +x

if [ -z "${OPENBAO_UNSEAL_KEYS:-}" ]; then
  echo "[unseal-ci] OPENBAO_UNSEAL_KEYS not set — skipping; a sealed replica will raise the OpenBaoSealed alert"
  exit 0
fi

mapfile -t keys < <(tr ',' '\n' <<<"$OPENBAO_UNSEAL_KEYS" | sed '/^[[:space:]]*$/d')
[ "${#keys[@]}" -ge 3 ] || { echo "[unseal-ci] need at least 3 key shares, got ${#keys[@]}" >&2; exit 1; }

pods="${OPENBAO_PODS:-openbao-0 openbao-1 openbao-2}"
rc=0
for pod in $pods; do
  sealed=$(kubectl -n openbao exec "$pod" -- bao status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo unreachable)
  case "$sealed" in
    false) echo "[unseal-ci] $pod already unsealed"; continue ;;
    true) ;;
    *) echo "[unseal-ci] $pod unreachable ($sealed) — skipping"; rc=1; continue ;;
  esac
  for key in "${keys[@]}"; do
    kubectl -n openbao exec "$pod" -- bao operator unseal -format=json "$key" >/dev/null 2>&1 || true
    sealed=$(kubectl -n openbao exec "$pod" -- bao status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo true)
    [ "$sealed" = true ] || break
  done
  if [ "$sealed" = false ]; then echo "[unseal-ci] $pod unsealed"; else echo "[unseal-ci] $pod still sealed after ${#keys[@]} shares" >&2; rc=1; fi
done
exit "$rc"
