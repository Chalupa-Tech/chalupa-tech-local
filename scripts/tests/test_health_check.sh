#!/usr/bin/env bash
# Unit tests for scripts/health-check.sh with stubbed ssh/kubectl/curl.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../health-check.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export HC_LOG="$tmp/calls.log"

# ssh stub: answers pve1 commands. HC_STUB_GUEST_STOPPED=<vmid> marks one guest stopped.
cat > "$tmp/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$HC_LOG"
cmd="${*: -1}"
case "$cmd" in
  true) exit 0 ;;
  *"qm list"*)
    echo "      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
    for id in 101 250; do st=running; [ "${HC_STUB_GUEST_STOPPED:-}" = "$id" ] && st=stopped; printf '%7s name %s 1 1 1\n' "$id" "$st"; done ;;
  *"pct list"*)
    echo "VMID       Status     Lock         Name"
    for id in 100 200; do st=running; [ "${HC_STUB_GUEST_STOPPED:-}" = "$id" ] && st=stopped; printf '%s %s name\n' "$id" "$st"; done ;;
  *showmount*) echo "Export list for 192.168.1.40:"; echo "/mnt/PlexMedia/frame 10.10.10.0/24,192.168.1.0/24" ;;
  *) exit 1 ;;
esac
STUB
# kubectl stub
cat > "$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$HC_LOG"
args="$*"
case "$args" in
  *"get nodes"*)
    ready=True; [ "${HC_STUB_NODE_NOTREADY:-0}" = 1 ] && ready=False
    printf '{"items":['
    first=1; for n in talos-cp talos-cp-2 talos-cp-3 talos-worker-1 talos-worker-2 talos-worker-3; do
      [ $first = 1 ] || printf ','; first=0
      r=True; [ "$n" = talos-worker-3 ] && r=$ready
      printf '{"metadata":{"name":"%s"},"status":{"conditions":[{"type":"Ready","status":"%s"}]}}' "$n" "$r"
    done; printf ']}\n' ;;
  *"get applications"*)
    h=Healthy; [ "${HC_STUB_APP_DEGRADED:-0}" = 1 ] && h=Degraded
    printf '{"items":[{"metadata":{"name":"argocd"},"status":{"health":{"status":"Healthy"}}},{"metadata":{"name":"openbao"},"status":{"health":{"status":"%s"}}}]}\n' "$h" ;;
  *"exec openbao-2"*"bao status"*)
    s=false; [ "${HC_STUB_SEALED:-0}" = 1 ] && s=true; printf '{"sealed":%s}\n' "$s" ;;
  *"bao status"*) printf '{"sealed":false}\n' ;;
  *"get externalsecret"*)
    printf '{"items":[{"metadata":{"namespace":"media","name":"x"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}\n' ;;
  *) exit 1 ;;
esac
STUB
# curl stub: -w prints an HTTP code; succeed unless HC_STUB_HTTP_DOWN=1
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$HC_LOG"
[ "${HC_STUB_HTTP_DOWN:-0}" = 1 ] && exit 7
case "$*" in *"-w"*) echo 200 ;; *) echo '<MediaContainer/>' ;; esac
STUB
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export KUBECONFIG="$tmp/kubeconfig"; : > "$KUBECONFIG"

fail() { echo "FAIL: $1"; exit 1; }
reset() { : > "$HC_LOG"; unset HC_STUB_SEALED HC_STUB_NODE_NOTREADY HC_STUB_APP_DEGRADED HC_STUB_GUEST_STOPPED HC_STUB_HTTP_DOWN; }
names="pve-ssh guests-running talos-nodes-ready argocd-healthy openbao-unsealed externalsecrets-ready plex-identity ha-http truenas-nfs"

all_green_exits_zero() {
  reset; out=$(bash "$script") || fail "all_green_exits_zero: exit $?: $out"
  for n in $names; do grep -q "^ok $n$" <<<"$out" || fail "all_green_exits_zero: missing 'ok $n'"; done
}
fails_on_sealed_openbao() {
  reset; export HC_STUB_SEALED=1
  if out=$(bash "$script"); then fail "fails_on_sealed_openbao: exited 0"; fi
  grep -q '^FAIL openbao-unsealed: openbao-2' <<<"$out" || fail "fails_on_sealed_openbao: wrong message: $out"
}
fails_on_node_not_ready() {
  reset; export HC_STUB_NODE_NOTREADY=1
  if out=$(bash "$script"); then fail "fails_on_node_not_ready: exited 0"; fi
  grep -q '^FAIL talos-nodes-ready: talos-worker-3' <<<"$out" || fail "fails_on_node_not_ready: $out"
}
fails_on_degraded_app() {
  reset; export HC_STUB_APP_DEGRADED=1
  if out=$(bash "$script"); then fail "fails_on_degraded_app: exited 0"; fi
  grep -q '^FAIL argocd-healthy: openbao=Degraded' <<<"$out" || fail "fails_on_degraded_app: $out"
}
fails_on_stopped_guest() {
  reset; export HC_STUB_GUEST_STOPPED=200
  if out=$(bash "$script"); then fail "fails_on_stopped_guest: exited 0"; fi
  grep -q '^FAIL guests-running: 200' <<<"$out" || fail "fails_on_stopped_guest: $out"
}
reports_every_check_even_after_failure() {
  reset; export HC_STUB_SEALED=1 HC_STUB_HTTP_DOWN=1
  out=$(bash "$script") || true
  for n in $names; do grep -qE "^(ok|FAIL) $n" <<<"$out" || fail "reports_every_check_even_after_failure: no line for $n"; done
  grep -q '^FAIL plex-identity' <<<"$out" || fail "reports_every_check_even_after_failure: plex should FAIL"
}

for t in all_green_exits_zero fails_on_sealed_openbao fails_on_node_not_ready fails_on_degraded_app fails_on_stopped_guest reports_every_check_even_after_failure; do
  "$t"; echo "ok $t"
done
echo PASS
