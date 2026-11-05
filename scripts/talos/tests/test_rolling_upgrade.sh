#!/usr/bin/env bash
# Unit tests for scripts/talos/rolling-upgrade.sh with stubbed talosctl, kubectl
# and unseal helper. Node state lives in $STATE_DIR/<ip> (Talos tag) and
# $STATE_DIR/k8s (kubelet version); STUB_FAIL_NODE=<ip> makes that node's
# upgrade "hang" (version never changes) so the gate times out.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../rolling-upgrade.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"
export STATE_DIR="$tmp/state" CALL_LOG="$tmp/calls.log"
export GATE_ATTEMPTS=2 GATE_SLEEP=0 TALOSCONFIG="$tmp/tc" KUBECONFIG="$tmp/kc"; : > "$TALOSCONFIG"; : > "$KUBECONFIG"
export UNSEAL_CI="$tmp/bin/unseal-ci.sh" ETCD_SNAPSHOT_PATH="$tmp/etcd.snap"
export UNSEAL_WAIT_ATTEMPTS=3 UNSEAL_WAIT_SLEEP=0
cps="192.168.1.225 192.168.1.228 192.168.1.229"; workers="192.168.1.226 192.168.1.227 192.168.1.232"

cat > "$tmp/bin/talosctl" <<'STUB'
#!/usr/bin/env bash
printf 'talosctl %s\n' "$*" >> "$CALL_LOG"
node=""; args=("$@"); for ((i=0;i<$#;i++)); do [ "${args[$i]}" = -n ] && node="${args[$((i+1))]}"; done
case "$*" in
  *" version"*) printf 'Client:\n\tTag: v9.9.9\nServer:\n\tNODE: %s\n\tTag: %s\n' "$node" "$(cat "$STATE_DIR/$node")" ;;
  *" upgrade --image "*)
    img=$(sed -E 's/.*--image ([^ ]+).*/\1/' <<<"$*"); ver=${img##*:}
    [ "${STUB_CMD_FAIL:-}" = "$node" ] && { echo "rpc error: connection reset" >&2; exit 1; }
    echo "$ver" > "$STATE_DIR/$node"
    [ "${STUB_FAIL_NODE:-}" = "$node" ] && echo degraded > "$STATE_DIR/apps"
    [ "${STUB_SEAL_AFTER:-}" = "$node" ] && echo openbao-0 > "$STATE_DIR/sealed"
    exit 0 ;;
  *" rollback"*) echo "rolled-back" > "$STATE_DIR/$node" ;;
  *"etcd snapshot "*) f="${!#}"; echo snap > "$f" ;;
  *"etcd status"*) printf 'NODE MEMBER DB_SIZE LEADER\n'; IFS=, read -ra ns <<<"$node"; for n in "${ns[@]}"; do printf '%s abc 72MB abc\n' "$n"; done ;;
  *"upgrade-k8s --to "*) echo "${!#}" > "$STATE_DIR/k8s" ;;
  *) echo "unexpected talosctl: $*" >&2; exit 1 ;;
esac
STUB
cat > "$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$CALL_LOG"
case "$*" in
  *"get nodes -o json"*)
    printf '{"items":['; first=1
    for ip in 192.168.1.225 192.168.1.228 192.168.1.229 192.168.1.226 192.168.1.227 192.168.1.232; do
      [ $first = 1 ] || printf ','; first=0
      r=True; [ "$(cat "$STATE_DIR/$ip")" = rolled-back ] && r=False
      printf '{"metadata":{"name":"n%s"},"status":{"conditions":[{"type":"Ready","status":"%s"}],"nodeInfo":{"kubeletVersion":"v%s"},"addresses":[{"type":"InternalIP","address":"%s"}]}}' "${ip##*.}" "$r" "$(cat "$STATE_DIR/k8s")" "$ip"
    done; printf ']}\n' ;;
  *"get applications"*) h=Healthy; [ -f "$STATE_DIR/apps" ] && h=Degraded; printf '{"items":[{"metadata":{"name":"argocd"},"status":{"health":{"status":"Healthy"}}},{"metadata":{"name":"traefik"},"status":{"health":{"status":"%s"}}}]}\n' "$h" ;;
  *"uncordon"*) exit 0 ;;
  *"get clustersecretstore"*) printf 'True\n' ;;
  *"exec openbao-"*"bao status"*)
    pod=$(sed -E 's/.*exec (openbao-[0-9]).*/\1/' <<<"$*")
    if [ -f "$STATE_DIR/sealed" ] && [ "$(cat "$STATE_DIR/sealed")" = "$pod" ]; then
      # STUB_AUTO_UNSEAL_AFTER=<n>: the replica auto-unseals (OCI KMS) after n status polls
      if [ -n "${STUB_AUTO_UNSEAL_AFTER:-}" ]; then n=$(( $(cat "$STATE_DIR/polls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE_DIR/polls"; [ "$n" -ge "$STUB_AUTO_UNSEAL_AFTER" ] && rm -f "$STATE_DIR/sealed"; fi
      printf '{"sealed":true}\n'; exit 2
    else printf '{"sealed":false}\n'; fi ;;
  *) echo "unexpected kubectl: $*" >&2; exit 1 ;;
esac
STUB
# shellcheck disable=SC2016  # stub body is meant to be literal
printf '#!/usr/bin/env bash\nprintf "unseal-ci %%s\\n" "${OPENBAO_UNSEAL_KEYS:+keys}" >> "$CALL_LOG"\n[ -n "${OPENBAO_UNSEAL_KEYS:-}" ] && rm -f "$STATE_DIR/sealed"; exit 0\n' > "$tmp/bin/unseal-ci.sh"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

fail() { echo "FAIL: $1"; exit 1; }
reset() { : > "$CALL_LOG"; for ip in $cps $workers; do echo v1.14.1 > "$STATE_DIR/$ip"; done; echo 1.36.0 > "$STATE_DIR/k8s"; rm -f "$ETCD_SNAPSHOT_PATH" "$STATE_DIR/sealed" "$STATE_DIR/apps" "$STATE_DIR/polls"; unset STUB_FAIL_NODE STUB_CMD_FAIL STUB_SEAL_AFTER STUB_AUTO_UNSEAL_AFTER OPENBAO_UNSEAL_KEYS; }
run() { set +e; bash "$script" --talos-version "$1" --k8s-version "$2" --schematic abc123 >"$tmp/out" 2>&1; rc=$?; set -e; return $rc; }
upgrades() { grep -E '^talosctl .*upgrade --image' "$CALL_LOG" | sed -E 's/.*-n ([0-9.]+).*/\1/' | paste -sd' ' -; }

snapshots_etcd_first() {
  reset; rc=0; run v1.14.5 1.36.0 || rc=$?; [ $rc = 0 ] || fail "snapshots_etcd_first: rc $rc: $(cat "$tmp/out")"
  [ -f "$ETCD_SNAPSHOT_PATH" ] || fail "snapshots_etcd_first: no snapshot file"
  first=$(grep -E '^talosctl' "$CALL_LOG" | grep -nE 'etcd snapshot|upgrade --image' | head -1)
  grep -q 'etcd snapshot' <<<"$first" || fail "snapshots_etcd_first: first talos op was: $first"
}
upgrades_cp_before_workers() {
  reset; run v1.14.5 1.36.0 || fail "upgrades_cp_before_workers: exit"
  [ "$(upgrades)" = "$cps $workers" ] || fail "upgrades_cp_before_workers: order was '$(upgrades)'"
  for ip in $cps $workers; do [ "$(cat "$STATE_DIR/$ip")" = v1.14.5 ] || fail "upgrades_cp_before_workers: $ip not upgraded"; done
  grep -q 'factory.talos.dev/installer/abc123:v1.14.5' "$CALL_LOG" || fail "upgrades_cp_before_workers: installer image: $(grep upgrade "$CALL_LOG" | head -1)"
  grep -q -- '--preserve' "$CALL_LOG" || fail "upgrades_cp_before_workers: --preserve missing"
  ! grep -q 'upgrade-k8s' "$CALL_LOG" || fail "upgrades_cp_before_workers: upgrade-k8s ran although the pin matches"
}
skips_nodes_already_at_version() {
  reset; echo v1.14.5 > "$STATE_DIR/192.168.1.225"; echo v1.14.5 > "$STATE_DIR/192.168.1.226"
  run v1.14.5 1.36.0 || fail "skips: exit $?: $(cat "$tmp/out")"
  [ "$(upgrades)" = "192.168.1.228 192.168.1.229 192.168.1.227 192.168.1.232" ] || fail "skips: upgraded '$(upgrades)'"
  grep -q '192.168.1.225: skipped' "$tmp/out" || fail "skips: no skipped line: $(cat "$tmp/out")"
}
refuses_when_openbao_sealed_without_keys() {
  reset; echo openbao-2 > "$STATE_DIR/sealed"
  rc=0; run v1.14.5 1.36.0 || rc=$?; [ $rc = 1 ] || fail "refuses_sealed: rc $rc"
  [ -z "$(upgrades)" ] || fail "refuses_sealed: upgraded nodes: $(upgrades)"
  grep -qi 'sealed' "$tmp/out" || fail "refuses_sealed: message: $(cat "$tmp/out")"
}
unseals_when_keys_present() {
  reset; echo openbao-2 > "$STATE_DIR/sealed"; export OPENBAO_UNSEAL_KEYS=$'a\nb\nc'
  run v1.14.5 1.36.0 || fail "unseals_when_keys_present: exit $?: $(cat "$tmp/out")"
  grep -q '^unseal-ci keys' "$CALL_LOG" || fail "unseals_when_keys_present: helper not called"
  [ "$(upgrades)" = "$cps $workers" ] || fail "unseals_when_keys_present: nodes: $(upgrades)"
}
rolls_back_only_a_node_that_booted_the_new_version() {
  # upgrade command succeeds, node boots v1.14.5, but the gate (apps Healthy) never clears
  reset; export STUB_FAIL_NODE=192.168.1.228
  rc=0; run v1.14.5 1.36.0 || rc=$?; [ $rc = 1 ] || fail "rollback_new_version: rc $rc"
  [ "$(upgrades)" = "192.168.1.225 192.168.1.228" ] || fail "rollback_new_version: upgraded '$(upgrades)'"
  grep -q 'talosctl .*-n 192.168.1.228 rollback' "$CALL_LOG" || fail "rollback_new_version: no rollback: $(grep rollback "$CALL_LOG" || true)"
  grep -q '192.168.1.228: FAILED' "$tmp/out" || fail "rollback_new_version: no FAILED line: $(cat "$tmp/out")"
  [ "$(cat "$STATE_DIR/192.168.1.229")" = v1.14.1 ] || fail "rollback_new_version: touched the next node"
}
no_rollback_when_upgrade_command_fails_before_boot() {
  # transient talosctl error (VIP reconnect, drain blocked): node is still on the old version — leave it alone, uncordon, stop
  reset; export STUB_CMD_FAIL=192.168.1.228
  rc=0; run v1.14.5 1.36.0 || rc=$?; [ $rc = 1 ] || fail "no_rollback_old_version: rc $rc"
  ! grep -q 'rollback' "$CALL_LOG" || fail "no_rollback_old_version: rolled back a node still on the old version"
  grep -q 'kubectl uncordon' "$CALL_LOG" || fail "no_rollback_old_version: node left cordoned"
  [ "$(cat "$STATE_DIR/192.168.1.228")" = v1.14.1 ] || fail "no_rollback_old_version: version changed"
  [ "$(cat "$STATE_DIR/192.168.1.229")" = v1.14.1 ] || fail "no_rollback_old_version: touched the next node"
}
stops_before_next_node_when_sealed_without_keys() {
  # the drain of .226 reseals a replica; without keys the run must stop cleanly before .227 (PDB would block), no rollback
  reset; export STUB_SEAL_AFTER=192.168.1.226
  rc=0; run v1.14.5 1.36.0 || rc=$?; [ $rc = 1 ] || fail "stops_sealed: rc $rc"
  [ "$(upgrades)" = "$cps 192.168.1.226" ] || fail "stops_sealed: upgraded '$(upgrades)'"
  ! grep -q 'rollback' "$CALL_LOG" || fail "stops_sealed: rolled back"
  grep -qi 'sealed' "$tmp/out" || fail "stops_sealed: message: $(cat "$tmp/out")"
}
continues_past_resealed_replica_with_keys() {
  reset; export STUB_SEAL_AFTER=192.168.1.226 OPENBAO_UNSEAL_KEYS=$'a\nb\nc'
  run v1.14.5 1.36.0 || fail "continues_with_keys: exit $?: $(cat "$tmp/out")"
  [ "$(upgrades)" = "$cps $workers" ] || fail "continues_with_keys: nodes: $(upgrades)"
  grep -q '^unseal-ci keys' "$CALL_LOG" || fail "continues_with_keys: helper not called"
}
etcd_gate_checks_all_control_planes() {
  reset; run v1.14.5 1.36.0 || fail "etcd_all_cps: exit"
  grep -q 'etcd status' "$CALL_LOG" || fail "etcd_all_cps: no etcd status"
  grep 'etcd status' "$CALL_LOG" | grep -q -- '-n 192.168.1.225,192.168.1.228,192.168.1.229' || fail "etcd_all_cps: status not queried on all CPs: $(grep 'etcd status' "$CALL_LOG" | head -1)"
}
k8s_upgrade_uses_repo_pin_only() {
  reset; echo 1.36.0 > "$STATE_DIR/k8s"
  run v1.14.5 1.36.6 || fail "k8s_pin: exit $?: $(cat "$tmp/out")"
  [ "$(grep -c 'upgrade-k8s --to 1.36.6' "$CALL_LOG")" = 1 ] || fail "k8s_pin: upgrade-k8s calls: $(grep upgrade-k8s "$CALL_LOG" || true)"
  [ "$(cat "$STATE_DIR/k8s")" = 1.36.6 ] || fail "k8s_pin: k8s not upgraded"
  last=$(grep -nE 'upgrade --image|upgrade-k8s' "$CALL_LOG" | tail -1); grep -q upgrade-k8s <<<"$last" || fail "k8s_pin: upgrade-k8s must run after node upgrades"
}
no_k8s_downgrade_when_cluster_is_ahead() {
  reset; for ip in $cps $workers; do echo v1.14.5 > "$STATE_DIR/$ip"; done; echo 1.36.1 > "$STATE_DIR/k8s"
  run v1.14.5 1.36.0 || fail "no_k8s_downgrade: exit $?: $(cat "$tmp/out")"
  ! grep -q 'upgrade-k8s' "$CALL_LOG" || fail "no_k8s_downgrade: attempted a downgrade"
}
nothing_to_do_is_success() {
  reset; for ip in $cps $workers; do echo v1.14.5 > "$STATE_DIR/$ip"; done
  run v1.14.5 1.36.0 || fail "nothing_to_do: exit $?"
  [ -z "$(upgrades)" ] || fail "nothing_to_do: upgraded $(upgrades)"
  ! grep -q 'etcd snapshot' "$CALL_LOG" || fail "nothing_to_do: took a snapshot for nothing"
}

waits_for_auto_unseal_without_keys() {
  # OCI KMS auto-unseal: the replica drained off the first node reseals, then
  # unseals by itself a couple of polls later; the run must wait and continue.
  reset; export STUB_SEAL_AFTER=192.168.1.225 STUB_AUTO_UNSEAL_AFTER=2
  rc=0; run v1.14.5 1.36.0 || rc=$?; [ $rc = 0 ] || fail "waits_auto: rc $rc: $(cat "$tmp/out")"
  [ "$(upgrades)" = "$cps $workers" ] || fail "waits_auto: upgraded '$(upgrades)'"
  ! grep -q 'unseal-ci keys' "$CALL_LOG" || fail "waits_auto: used keys"
  grep -qi 'waiting' "$tmp/out" || fail "waits_auto: no waiting message: $(cat "$tmp/out")"
}
gives_up_after_the_unseal_wait() {
  reset; export STUB_SEAL_AFTER=192.168.1.225 STUB_AUTO_UNSEAL_AFTER=99
  rc=0; run v1.14.5 1.36.0 || rc=$?; [ $rc = 1 ] || fail "gives_up: rc $rc"
  [ "$(upgrades)" = "192.168.1.225" ] || fail "gives_up: upgraded '$(upgrades)'"
  [ "$(cat "$STATE_DIR/polls")" -ge 3 ] || fail "gives_up: polled only $(cat "$STATE_DIR/polls") times"
}
for t in snapshots_etcd_first upgrades_cp_before_workers skips_nodes_already_at_version refuses_when_openbao_sealed_without_keys unseals_when_keys_present rolls_back_only_a_node_that_booted_the_new_version no_rollback_when_upgrade_command_fails_before_boot stops_before_next_node_when_sealed_without_keys continues_past_resealed_replica_with_keys etcd_gate_checks_all_control_planes k8s_upgrade_uses_repo_pin_only no_k8s_downgrade_when_cluster_is_ahead nothing_to_do_is_success waits_for_auto_unseal_without_keys gives_up_after_the_unseal_wait; do
  "$t"; echo "ok $t"
done
echo PASS
