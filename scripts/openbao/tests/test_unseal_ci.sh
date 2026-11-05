#!/usr/bin/env bash
# Unit tests for scripts/openbao/unseal-ci.sh with a stubbed kubectl.
# The stub mimics real `bao status` semantics: exit 2 while sealed, 0 when
# unsealed; a pod becomes unsealed after UNSEAL_NEEDED successful shares.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../unseal-ci.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"
export STATE_DIR="$tmp/state" CALL_LOG="$tmp/calls.log"
cat > "$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# kubectl -n openbao exec <pod> -- bao status -format=json | bao operator unseal ...
pod=$4; shift 5   # drop: -n openbao exec <pod> --
printf 'kubectl %s %s\n' "$pod" "$*" >> "$CALL_LOG"
f="$STATE_DIR/$pod"
[ -f "$f" ] || { echo "Error from server: pod not found" >&2; exit 1; }
sealed=$(cat "$f")
case "$*" in
  "bao status -format=json")
    if [ "$sealed" = 1 ]; then printf '{"sealed":true}\n'; exit 2; else printf '{"sealed":false}\n'; exit 0; fi ;;
  "bao operator unseal -format=json "*)
    key="${!#}"
    [ "$key" = bad ] && { echo "invalid key" >&2; exit 1; }
    n=$(cat "$STATE_DIR/$pod.progress" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$STATE_DIR/$pod.progress"
    [ "$n" -ge "${UNSEAL_NEEDED:-3}" ] && echo 0 > "$f"
    printf '{"sealed":%s}\n' "$( [ "$(cat "$f")" = 1 ] && echo true || echo false )" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/kubectl"
export PATH="$tmp/bin:$PATH" KUBECONFIG="$tmp/kc"; : > "$KUBECONFIG"
export UNSEAL_WAIT_ATTEMPTS=2 UNSEAL_WAIT_SLEEP=0

fail() { echo "FAIL: $1"; exit 1; }
reset() { : > "$CALL_LOG"; rm -f "$STATE_DIR"/*; for p in openbao-0 openbao-1 openbao-2; do echo 0 > "$STATE_DIR/$p"; done; unset OPENBAO_UNSEAL_KEYS; }
keys=$'k1\nk2\nk3'

skips_without_keys() {
  reset; out=$(bash "$script") || fail "skips_without_keys: exit $?"
  grep -q 'not set' <<<"$out" || fail "skips_without_keys: $out"
  [ ! -s "$CALL_LOG" ] || fail "skips_without_keys: kubectl was called"
}
unseals_sealed_replica() {
  reset; echo 1 > "$STATE_DIR/openbao-2"; export OPENBAO_UNSEAL_KEYS="$keys"
  out=$(bash "$script") || fail "unseals_sealed_replica: exit $?: $out"
  [ "$(cat "$STATE_DIR/openbao-2")" = 0 ] || fail "unseals_sealed_replica: still sealed"
  [ "$(grep -c 'openbao-2 bao operator unseal' "$CALL_LOG")" = 3 ] || fail "unseals_sealed_replica: shares sent $(grep -c 'operator unseal' "$CALL_LOG")"
  grep -q 'openbao-2 unsealed' <<<"$out" || fail "unseals_sealed_replica: message: $out"
}
leaves_unsealed_alone() {
  reset; export OPENBAO_UNSEAL_KEYS="$keys"
  bash "$script" >/dev/null || fail "leaves_unsealed_alone: exit $?"
  ! grep -q 'operator unseal' "$CALL_LOG" || fail "leaves_unsealed_alone: sent shares to an unsealed pod"
}
stops_sending_once_unsealed() {
  reset; echo 1 > "$STATE_DIR/openbao-0"; export OPENBAO_UNSEAL_KEYS=$'k1\nk2\nk3\nk4\nk5' UNSEAL_NEEDED=2
  bash "$script" >/dev/null || fail "stops_sending_once_unsealed: exit $?"
  [ "$(grep -c 'openbao-0 bao operator unseal' "$CALL_LOG")" = 2 ] || fail "stops_sending_once_unsealed: sent $(grep -c 'openbao-0 bao operator unseal' "$CALL_LOG") shares"
  unset UNSEAL_NEEDED
}
fails_when_still_sealed() {
  reset; echo 1 > "$STATE_DIR/openbao-1"; export OPENBAO_UNSEAL_KEYS=$'bad\nbad\nbad'
  if bash "$script" >/dev/null 2>&1; then fail "fails_when_still_sealed: exited 0"; fi
}
waits_for_unreachable_pod() {
  reset; rm -f "$STATE_DIR/openbao-2"; export OPENBAO_UNSEAL_KEYS="$keys"
  if bash "$script" >"$tmp/out" 2>&1; then fail "waits_for_unreachable_pod: exited 0"; fi
  [ "$(grep -c 'openbao-2 bao status' "$CALL_LOG")" -ge 2 ] || fail "waits_for_unreachable_pod: no retry: $(cat "$CALL_LOG")"
}
never_prints_keys() {
  reset; echo 1 > "$STATE_DIR/openbao-2"; export OPENBAO_UNSEAL_KEYS=$'sekrit1\nsekrit2\nsekrit3'
  out=$(bash "$script" 2>&1) || true
  ! grep -q sekrit <<<"$out" || fail "never_prints_keys: key share in output"
}

for t in skips_without_keys unseals_sealed_replica leaves_unsealed_alone stops_sending_once_unsealed fails_when_still_sealed waits_for_unreachable_pod never_prints_keys; do
  "$t"; echo "ok $t"
done
echo PASS
