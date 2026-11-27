#!/usr/bin/env bash
# Unit tests for scripts/k8s/prune-orphans.sh with a stubbed kubectl.
# The stub records every call and answers reads from fixture files:
#   $tmp/apps.json      `get applications -o json`
#   $tmp/pods.json      `get pods -o json` (any namespace)
#   $tmp/rb.json        `get rolebindings -o json` (namespaced or -A)
#   $tmp/crb.json       `get clusterrolebindings -o json`
#   STUB_TRACKING       tracking-id annotation returned for every resource ("<app>:x")
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../prune-orphans.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export CALL_LOG="$tmp/calls.log" FIX="$tmp"
cat > "$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$CALL_LOG"
args="$*"
case "$args" in
  *"get applications -o json"*) cat "$FIX/apps.json" ;;
  *"get pods -o json"*) cat "$FIX/pods.json" ;;
  *"get rolebindings"*"-o json"*) cat "$FIX/rb.json" ;;
  *"get clusterrolebindings -o json"*) cat "$FIX/crb.json" ;;
  *"tracking-id"*) printf '%s' "${STUB_TRACKING-demo:x}" ;;
  *"delete "*) exit 0 ;;
  *"annotate application"*) exit 0 ;;
  *) echo "unexpected kubectl: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/kubectl"
export PATH="$tmp/bin:$PATH" KUBECONFIG="$tmp/kc"; : > "$KUBECONFIG"
fail() { echo "FAIL: $1"; exit 1; }
empty='{"items":[]}'
reset() {
  : > "$CALL_LOG"; unset STUB_TRACKING
  for f in pods rb crb; do echo "$empty" > "$tmp/$f.json"; done
}
orphans() { # each arg: group|kind|namespace|name  (empty group/ns allowed)
  local res="" g k n m
  for o in "$@"; do
    IFS='|' read -r g k n m <<< "$o"
    res="$res${res:+,}{\"group\":\"$g\",\"kind\":\"$k\",\"namespace\":\"$n\",\"name\":\"$m\",\"status\":\"OutOfSync\",\"requiresPruning\":true}"
  done
  echo "{\"items\":[{\"metadata\":{\"name\":\"demo\"},\"status\":{\"resources\":[$res,{\"kind\":\"Deployment\",\"name\":\"keep\",\"status\":\"Synced\"}]}}]}" > "$tmp/apps.json"
}
run() { set +e; bash "$script" "$@" >"$tmp/out" 2>&1; rc=$?; set -e; return $rc; }
deletes() { grep '^kubectl delete' "$CALL_LOG" || true; }

prunes_allowlisted_kinds() {
  reset
  orphans "rbac.authorization.k8s.io|ClusterRoleBinding||old-crb" "|ConfigMap|ns1|old-cm" \
    "|ServiceAccount|ns1|old-sa" "rbac.authorization.k8s.io|Role|ns1|old-role"
  run || fail "prunes_allowlisted_kinds: rc $rc: $(cat "$tmp/out")"
  [ "$(deletes | wc -l | tr -d ' ')" = 4 ] || fail "prunes_allowlisted_kinds: expected 4 deletes, got: $(deletes)"
  deletes | grep -q 'ClusterRoleBinding.rbac.authorization.k8s.io/old-crb --ignore-not-found' \
    || fail "prunes_allowlisted_kinds: cluster-scoped delete must have no namespace: $(deletes)"
  deletes | grep -q 'ConfigMap/old-cm --namespace=ns1' || fail "prunes_allowlisted_kinds: cm delete wrong: $(deletes)"
  grep -q 'annotate application demo argocd.argoproj.io/refresh=normal' "$CALL_LOG" \
    || fail "prunes_allowlisted_kinds: app not refreshed"
}
never_prunes_other_kinds() {
  reset
  orphans "apiextensions.k8s.io|CustomResourceDefinition||widgets.example.com" "|PersistentVolumeClaim|ns1|data" \
    "|Secret|ns1|creds" "|Service|ns1|svc" "apps|Deployment|ns1|web"
  run || fail "never_prunes_other_kinds: rc $rc"
  [ -z "$(deletes)" ] || fail "never_prunes_other_kinds: deleted: $(deletes)"
  [ "$(grep -c '::warning::.*not on the prune allowlist' "$tmp/out")" = 5 ] \
    || fail "never_prunes_other_kinds: expected 5 warnings: $(cat "$tmp/out")"
  grep -q annotate "$CALL_LOG" && fail "never_prunes_other_kinds: refreshed with nothing pruned"
  true
}
skips_configmap_still_mounted() {
  reset
  orphans "|ConfigMap|ns1|old-cm"
  echo '{"items":[{"spec":{"volumes":[{"name":"v","projected":{"sources":[{"configMap":{"name":"old-cm"}}]}}]}}]}' > "$tmp/pods.json"
  run || fail "skips_configmap_still_mounted: rc $rc"
  [ -z "$(deletes)" ] || fail "skips_configmap_still_mounted: deleted a mounted cm"
  echo '{"items":[{"spec":{"containers":[{"env":[{"valueFrom":{"configMapKeyRef":{"name":"old-cm","key":"k"}}}]}]}}]}' > "$tmp/pods.json"
  : > "$CALL_LOG"; run || true
  [ -z "$(deletes)" ] || fail "skips_configmap_still_mounted: deleted an env-referenced cm"
}
skips_serviceaccount_in_use() {
  reset
  orphans "|ServiceAccount|ns1|old-sa"
  echo '{"items":[{"spec":{"serviceAccountName":"old-sa"}}]}' > "$tmp/pods.json"
  run || fail "skips_serviceaccount_in_use: rc $rc"
  [ -z "$(deletes)" ] || fail "skips_serviceaccount_in_use: deleted an in-use sa"
}
skips_role_bound_by_live_binding() {
  reset
  orphans "rbac.authorization.k8s.io|ClusterRole||old-cr"
  echo '{"items":[{"kind":"ClusterRoleBinding","metadata":{"name":"keeper"},"roleRef":{"kind":"ClusterRole","name":"old-cr"}}]}' > "$tmp/crb.json"
  run || fail "skips_role_bound_by_live_binding: rc $rc"
  [ -z "$(deletes)" ] || fail "skips_role_bound_by_live_binding: deleted a bound clusterrole"
}
prunes_role_whose_only_binding_is_pruned() {
  reset
  orphans "rbac.authorization.k8s.io|Role|ns1|old-role" "rbac.authorization.k8s.io|RoleBinding|ns1|old-rb"
  echo '{"items":[{"kind":"RoleBinding","metadata":{"name":"old-rb","namespace":"ns1"},"roleRef":{"kind":"Role","name":"old-role"}}]}' > "$tmp/rb.json"
  run --dry-run || fail "prunes_role_whose_only_binding_is_pruned: rc $rc"
  grep -q 'would prune Role ns1/old-role' "$tmp/out" \
    || fail "prunes_role_whose_only_binding_is_pruned: role not pruned after its binding: $(cat "$tmp/out")"
  [ "$(grep -n 'would prune' "$tmp/out" | head -1 | grep -c RoleBinding)" = 1 ] \
    || fail "prunes_role_whose_only_binding_is_pruned: bindings must go first"
}
skips_foreign_tracking_id() {
  reset
  orphans "|ConfigMap|ns1|old-cm"
  export STUB_TRACKING="other-app:x"
  run || fail "skips_foreign_tracking_id: rc $rc"
  [ -z "$(deletes)" ] || fail "skips_foreign_tracking_id: deleted a resource owned by another app"
  export STUB_TRACKING=""
  : > "$CALL_LOG"; run || true
  [ -z "$(deletes)" ] || fail "skips_foreign_tracking_id: deleted an untracked resource"
}
dry_run_deletes_nothing() {
  reset
  orphans "|ConfigMap|ns1|old-cm" "rbac.authorization.k8s.io|ClusterRoleBinding||old-crb"
  run --dry-run || fail "dry_run_deletes_nothing: rc $rc"
  [ -z "$(deletes)" ] || fail "dry_run_deletes_nothing: deleted under --dry-run"
  grep -q annotate "$CALL_LOG" && fail "dry_run_deletes_nothing: refreshed under --dry-run"
  grep -q 'pruned=2 skipped=0 dry_run=1' "$tmp/out" || fail "dry_run_deletes_nothing: summary: $(cat "$tmp/out")"
}
no_orphans_is_a_noop() {
  reset
  echo '{"items":[{"metadata":{"name":"demo"},"status":{"resources":[{"kind":"ConfigMap","name":"x","status":"Synced"}]}}]}' > "$tmp/apps.json"
  run || fail "no_orphans_is_a_noop: rc $rc"
  grep -q 'No ArgoCD orphans' "$tmp/out" || fail "no_orphans_is_a_noop: $(cat "$tmp/out")"
}

for t in prunes_allowlisted_kinds never_prunes_other_kinds skips_configmap_still_mounted \
  skips_serviceaccount_in_use skips_role_bound_by_live_binding prunes_role_whose_only_binding_is_pruned \
  skips_foreign_tracking_id dry_run_deletes_nothing no_orphans_is_a_noop; do
  $t; echo "ok - $t"
done
