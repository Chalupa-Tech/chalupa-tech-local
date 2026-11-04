#!/usr/bin/env bash
# Unit tests for scripts/k8s/restore-drill.sh with a stubbed kubectl.
# The stub records every call and answers reads from env knobs:
#   STUB_RD_RESULT        latestMoverStatus.result for the ReplicationDestination (Successful)
#   STUB_RAFT_LS          output of the raft listing pod ("raft/raft.db")
#   STUB_DB_COUNT         pg_database count for radarr_main (1)
#   STUB_CNPG_PHASE       drill cluster phase ("Cluster in healthy state")
#   STUB_SNAPSHOT_INSPECT exit code of the raft snapshot inspect pod (0)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../restore-drill.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export CALL_LOG="$tmp/calls.log" DRILL_WAIT_SLEEP=0 DRILL_WAIT_ATTEMPTS=3
cat > "$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$CALL_LOG"
args="$*"
case "$args" in
  *"apply -f -"*) cat >> "$CALL_LOG.applied"; exit 0 ;;
  *"get replicationdestination"*"latestMoverStatus.result"*) printf '%s' "${STUB_RD_RESULT:-Successful}" ;;
  *"get cluster.postgresql.cnpg.io"*"status.phase"*) printf '%s' "${STUB_CNPG_PHASE:-Cluster in healthy state}" ;;
  *"get pvc"*) exit 0 ;;
  *"run raft-ls-drill"*) printf '%s\n' "${STUB_RAFT_LS:-raft/raft.db}" ;;
  *"run pg-restore-drill"*) printf '%s\n' "${STUB_DB_COUNT:-1}" ;;
  *"run snapshot-inspect-drill"*) exit "${STUB_SNAPSHOT_INSPECT:-0}" ;;
  *"delete"*) exit 0 ;;
  *"wait"*) exit 0 ;;
  *) echo "unexpected kubectl: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/kubectl"
export PATH="$tmp/bin:$PATH" KUBECONFIG="$tmp/kc"; : > "$KUBECONFIG"
fail() { echo "FAIL: $1"; exit 1; }
reset() { : > "$CALL_LOG"; rm -f "$CALL_LOG.applied"; unset STUB_RD_RESULT STUB_RAFT_LS STUB_DB_COUNT STUB_CNPG_PHASE STUB_SNAPSHOT_INSPECT; }
run() { set +e; bash "$script" >"$tmp/out" 2>&1; rc=$?; set -e; return $rc; }
deletes() { grep '^kubectl .*delete' "$CALL_LOG" || true; }

passes_when_all_green() {
  reset; rc=0; run || rc=$?; [ $rc = 0 ] || fail "passes_when_all_green: rc $rc: $(cat "$tmp/out")"
  grep -q 'kind: ReplicationDestination' "$CALL_LOG.applied" || fail "passes_when_all_green: no ReplicationDestination applied"
  grep -q 'kind: Cluster' "$CALL_LOG.applied" || fail "passes_when_all_green: no CNPG drill cluster applied"
  grep -q 'copyMethod: Direct' "$CALL_LOG.applied" || fail "passes_when_all_green: RD must use Direct"
}
only_drill_names_touched() {
  reset; run || true
  # every applied resource and every delete targets a name ending in -drill (or the drill restore PVC)
  names=$(grep -E '^\s+name: ' "$CALL_LOG.applied" | awk '{print $2}' | sort -u)
  for n in $names; do
    case "$n" in *-drill|*-drill-restore|*-drill-superuser) ;; *) fail "only_drill_names_touched: applied resource named '$n'" ;; esac
  done
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qE '(-drill|-drill-restore|-drill-superuser)( |$)' <<<"$line" || fail "only_drill_names_touched: delete without -drill name: $line"
  done <<<"$(deletes)"
  ! grep -qE 'delete .*(data-openbao-[0-9]|arrs-pg|arrs-pg-[0-9])( |$)' "$CALL_LOG" || fail "only_drill_names_touched: touched a live resource"
}
fails_when_restore_not_successful() {
  reset; export STUB_RD_RESULT=Failed
  rc=0; run || rc=$?; [ $rc = 1 ] || fail "fails_when_restore_not_successful: rc $rc"
  grep -q 'delete replicationdestination' "$CALL_LOG" || fail "fails_when_restore_not_successful: RD not cleaned up"
}
fails_when_raft_db_missing() {
  reset; export STUB_RAFT_LS="lost+found"
  rc=0; run || rc=$?; [ $rc = 1 ] || fail "fails_when_raft_db_missing: rc $rc"
}
fails_when_db_count_wrong() {
  reset; export STUB_DB_COUNT=0
  rc=0; run || rc=$?; [ $rc = 1 ] || fail "fails_when_db_count_wrong: rc $rc"
  grep -q 'delete cluster.postgresql.cnpg.io arrs-pg-drill' "$CALL_LOG" || fail "fails_when_db_count_wrong: drill cluster not deleted: $(deletes)"
}
fails_when_snapshot_inspect_fails() {
  reset; export STUB_SNAPSHOT_INSPECT=1
  rc=0; run || rc=$?; [ $rc = 1 ] || fail "fails_when_snapshot_inspect_fails: rc $rc"
}
cleans_up_on_failure() {
  reset; export STUB_CNPG_PHASE="Setting up primary"
  rc=0; run || rc=$?; [ $rc = 1 ] || fail "cleans_up_on_failure: rc $rc"
  grep -q 'delete cluster.postgresql.cnpg.io arrs-pg-drill' "$CALL_LOG" || fail "cleans_up_on_failure: CNPG drill cluster left behind"
  grep -q 'delete replicationdestination' "$CALL_LOG" || fail "cleans_up_on_failure: RD left behind"
}

override_container_named_after_pod() {
  # kubectl run --overrides strategic-merges containers by name: a different
  # name appends a second container and the attach goes to the default one.
  reset; run || true
  for pod in raft-ls-drill pg-restore-drill snapshot-inspect-drill; do
    line=$(grep "run $pod" "$CALL_LOG" || true)
    [ -n "$line" ] || fail "override_container_named_after_pod: no run for $pod"
    grep -q "\"name\":\"$pod\"" <<<"$line" || fail "override_container_named_after_pod: $pod override container not named $pod"
  done
}
cleanup_waits_before_reuse() {
  reset; run || true
  first_delete=$(grep -n 'delete replicationdestination data-openbao-0-drill' "$CALL_LOG" | head -1 | cut -d: -f2-)
  grep -q -- '--wait=true' <<<"$first_delete" || fail "cleanup_waits_before_reuse: pre-apply cleanup must wait: $first_delete"
}
failed_restore_exits_early() {
  reset; export STUB_RD_RESULT=Failed DRILL_WAIT_ATTEMPTS=50
  rc=0; run || rc=$?; [ $rc = 1 ] || fail "failed_restore_exits_early: rc $rc"
  [ "$(grep -c 'latestMoverStatus.result' "$CALL_LOG")" -le 2 ] || fail "failed_restore_exits_early: kept polling a Failed restore ($(grep -c 'latestMoverStatus.result' "$CALL_LOG") polls)"
  unset DRILL_WAIT_ATTEMPTS; export DRILL_WAIT_ATTEMPTS=3
}

for t in override_container_named_after_pod cleanup_waits_before_reuse failed_restore_exits_early passes_when_all_green only_drill_names_touched fails_when_restore_not_successful fails_when_raft_db_missing fails_when_db_count_wrong fails_when_snapshot_inspect_fails cleans_up_on_failure; do
  "$t"; echo "ok $t"
done
echo PASS
