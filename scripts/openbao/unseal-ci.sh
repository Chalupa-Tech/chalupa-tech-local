#!/usr/bin/env bash
# Unseal any sealed OpenBao replica from CI using Shamir shares in the
# OPENBAO_UNSEAL_KEYS environment variable (newline- or comma-separated;
# 3 of the 5 shares). If the variable is absent the script prints a notice
# and exits 0 so callers can treat unsealing as opt-in (spec §8).
#
# `bao status` exits 2 while sealed, so its exit code is deliberately
# ignored and only the JSON `sealed` field is read. Shares are never
# echoed (no `set -x`); like the workstation unseal.sh they travel as an
# argument of the in-pod `bao` command, which the API server's exec audit
# log could record. Pods that are not reachable yet (right after a host
# reboot) are retried UNSEAL_WAIT_ATTEMPTS times, UNSEAL_WAIT_SLEEP apart.
set -euo pipefail
set +x

if [ -z "${OPENBAO_UNSEAL_KEYS:-}" ]; then
  echo "[unseal-ci] OPENBAO_UNSEAL_KEYS not set — skipping; a sealed replica will raise the OpenBaoSealed alert"
  exit 0
fi

keys=()
while IFS= read -r line; do
  line="${line//[[:space:]]/}"
  [ -n "$line" ] && keys+=("$line")
done < <(tr ',' '\n' <<<"$OPENBAO_UNSEAL_KEYS")
[ "${#keys[@]}" -ge 3 ] || { echo "[unseal-ci] need at least 3 key shares, got ${#keys[@]}" >&2; exit 1; }

pods="${OPENBAO_PODS:-openbao-0 openbao-1 openbao-2}"
attempts="${UNSEAL_WAIT_ATTEMPTS:-20}"
sleep_s="${UNSEAL_WAIT_SLEEP:-15}"

# Prints true/false, or "unreachable" when the pod cannot be exec'd into.
sealed_state() {
  local out
  set +o pipefail
  out=$(kubectl -n openbao exec "$1" -- bao status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null)
  set -o pipefail
  case "$out" in true|false) echo "$out" ;; *) echo unreachable ;; esac
}

rc=0
for pod in $pods; do
  state=unreachable
  for ((i = 1; i <= attempts; i++)); do
    state=$(sealed_state "$pod")
    [ "$state" = unreachable ] || break
    [ "$i" -lt "$attempts" ] && sleep "$sleep_s"
  done
  case "$state" in
    false) echo "[unseal-ci] $pod already unsealed"; continue ;;
    unreachable) echo "[unseal-ci] $pod unreachable after $attempts attempts — skipping" >&2; rc=1; continue ;;
  esac
  sent=0
  for key in "${keys[@]}"; do
    kubectl -n openbao exec "$pod" -- bao operator unseal -format=json "$key" >/dev/null 2>&1 || true
    sent=$((sent + 1))
    state=$(sealed_state "$pod")
    [ "$state" = true ] || break
  done
  if [ "$state" = false ]; then
    echo "[unseal-ci] $pod unsealed ($sent share(s))"
  else
    echo "[unseal-ci] $pod still sealed after $sent share(s)" >&2
    rc=1
  fi
done
exit "$rc"
