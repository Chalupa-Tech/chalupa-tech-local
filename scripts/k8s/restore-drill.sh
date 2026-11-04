#!/usr/bin/env bash
# Cluster restore drill: prove the cluster backups restore, monthly, from a
# CI runner with KUBECONFIG set. Every resource it creates is named *-drill
# (or openbao-drill-restore) and is deleted by name at the end — also on
# failure, via the EXIT trap. It never touches a live PVC, cluster or secret.
#
#   1. VolSync ReplicationDestination (restic, Direct) of the openbao-0 raft
#      volume into a fresh PVC; assert raft/raft.db is present.
#   2. Throwaway CNPG cluster arrs-pg-drill (1 instance); load the newest
#      pg_dumpall archive; assert database radarr_main exists.
#   3. `bao operator raft snapshot inspect` on the newest raft snapshot.
set -euo pipefail

DRILL_WAIT_ATTEMPTS="${DRILL_WAIT_ATTEMPTS:-60}"   # x DRILL_WAIT_SLEEP = 15 min
DRILL_WAIT_SLEEP="${DRILL_WAIT_SLEEP:-15}"
OPENBAO_IMAGE="${OPENBAO_IMAGE:-quay.io/openbao/openbao:2.6.2}"
PG_IMAGE="${PG_IMAGE:-ghcr.io/cloudnative-pg/postgresql:18.6}"

failures=0
log() { printf '[cluster-drill] %s\n' "$*"; }
err() { printf '[cluster-drill] ERROR: %s\n' "$*" >&2; failures=$((failures + 1)); }

# cleanup [wait]: with "wait" it blocks until the objects are gone, which the
# pre-apply cleanup needs (a Terminating PVC from a previous failed run would
# otherwise swallow the new apply and vanish under the mover).
cleanup() {
  local w="--wait=false"; [ "${1:-}" = wait ] && w="--wait=true --timeout=180s"
  # shellcheck disable=SC2086  # $w is two flags
  kubectl -n openbao delete replicationdestination data-openbao-0-drill --ignore-not-found $w >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  kubectl -n openbao delete pvc openbao-drill-restore --ignore-not-found $w >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  kubectl -n media delete cluster.postgresql.cnpg.io arrs-pg-drill --ignore-not-found $w >/dev/null 2>&1 || true
  kubectl -n media delete secret arrs-pg-drill-superuser --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# wait_for <description> <command...> : retries until the command prints "ok";
# a command printing "failed" ends the wait immediately.
wait_for() {
  local what=$1; shift
  local i out
  for ((i = 1; i <= DRILL_WAIT_ATTEMPTS; i++)); do
    out=$("$@" 2>/dev/null || true)
    [ "$out" = ok ] && return 0
    if [ "$out" = failed ]; then err "$what reported failure"; return 1; fi
    [ "$i" -lt "$DRILL_WAIT_ATTEMPTS" ] && sleep "$DRILL_WAIT_SLEEP"
  done
  err "timed out waiting for $what"
  return 1
}

# ---------------------------------------------------------------- 1. VolSync
log "1/3 VolSync restore of openbao/data-openbao-0 into openbao-drill-restore"
cleanup wait
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openbao-drill-restore
  namespace: openbao
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: data-openbao-0-drill
  namespace: openbao
spec:
  trigger:
    manual: drill
  restic:
    repository: restic-data-openbao-0
    copyMethod: Direct
    destinationPVC: openbao-drill-restore
    moverSecurityContext:
      runAsUser: 100
      runAsGroup: 1000
      fsGroup: 1000
EOF
rd_result() {
  local r
  r=$(kubectl -n openbao get replicationdestination data-openbao-0-drill -o jsonpath='{.status.latestMoverStatus.result}')
  case "$r" in Successful) echo ok ;; Failed) echo failed ;; *) echo pending ;; esac
}
if wait_for "VolSync restore" rd_result; then
  listing=$(kubectl -n openbao run raft-ls-drill --rm -i --restart=Never --quiet --image=busybox:1.37 \
    --overrides="{\"spec\":{\"securityContext\":{\"runAsUser\":100,\"runAsGroup\":1000,\"fsGroup\":1000},\"containers\":[{\"name\":\"raft-ls-drill\",\"image\":\"busybox:1.37\",\"command\":[\"sh\",\"-c\",\"cd /data && find . -maxdepth 2 | sed 's|^./||'\"],\"volumeMounts\":[{\"name\":\"data\",\"mountPath\":\"/data\"}]}],\"volumes\":[{\"name\":\"data\",\"persistentVolumeClaim\":{\"claimName\":\"openbao-drill-restore\"}}]}}" 2>/dev/null || true)
  if grep -q '^raft/raft.db$' <<<"$listing"; then log "restored volume contains raft/raft.db — OK"; else err "restored volume lacks raft/raft.db: $listing"; fi
fi
kubectl -n openbao delete replicationdestination data-openbao-0-drill --ignore-not-found --wait=false >/dev/null 2>&1 || true
kubectl -n openbao delete pvc openbao-drill-restore --ignore-not-found --wait=false >/dev/null 2>&1 || true

# ------------------------------------------------------------------- 2. CNPG
log "2/3 throwaway CNPG cluster arrs-pg-drill + load newest pg_dumpall"
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: arrs-pg-drill-superuser
  namespace: media
type: kubernetes.io/basic-auth
stringData:
  username: postgres
  password: drill-only-password
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: arrs-pg-drill
  namespace: media
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6
  enableSuperuserAccess: true
  superuserSecret:
    name: arrs-pg-drill-superuser
  storage:
    size: 5Gi
    storageClass: local-path
EOF
cnpg_ready() {
  local p
  p=$(kubectl -n media get cluster.postgresql.cnpg.io arrs-pg-drill -o jsonpath='{.status.phase}')
  [ "$p" = "Cluster in healthy state" ] && echo ok || echo pending
}
if wait_for "CNPG drill cluster" cnpg_ready; then
  count=$(kubectl -n media run pg-restore-drill --rm -i --restart=Never --quiet --image="$PG_IMAGE" \
    --overrides="{\"spec\":{\"securityContext\":{\"runAsUser\":26,\"runAsGroup\":26,\"fsGroup\":26},\"containers\":[{\"name\":\"pg-restore-drill\",\"image\":\"$PG_IMAGE\",\"command\":[\"bash\",\"-c\",\"set -e; f=\$(ls -1 /backups/postgres/arrs-pg-*.sql.gz | sort | tail -n 1); gzip -dc \\\"\$f\\\" | psql -q -v ON_ERROR_STOP=0 -h arrs-pg-drill-rw -U postgres -d postgres >/dev/null; psql -tA -h arrs-pg-drill-rw -U postgres -d postgres -c \\\"select count(*) from pg_database where datname='radarr_main'\\\"\"],\"env\":[{\"name\":\"PGPASSWORD\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"arrs-pg-drill-superuser\",\"key\":\"password\"}}}],\"volumeMounts\":[{\"name\":\"backups\",\"mountPath\":\"/backups\",\"readOnly\":true}]}],\"volumes\":[{\"name\":\"backups\",\"persistentVolumeClaim\":{\"claimName\":\"backups-k8s\"}}]}}" 2>/dev/null | tr -d '[:space:]' || true)
  if [ "$count" = 1 ]; then log "dump restored; radarr_main present — OK"; else err "dump restore check failed (radarr_main count='$count')"; fi
fi
kubectl -n media delete cluster.postgresql.cnpg.io arrs-pg-drill --ignore-not-found --wait=false >/dev/null 2>&1 || true
kubectl -n media delete secret arrs-pg-drill-superuser --ignore-not-found >/dev/null 2>&1 || true

# ------------------------------------------------------- 3. raft snapshot file
log "3/3 inspect newest OpenBao raft snapshot"
if kubectl -n openbao run snapshot-inspect-drill --rm -i --restart=Never --quiet --image="$OPENBAO_IMAGE" \
    --overrides="{\"spec\":{\"securityContext\":{\"runAsUser\":100,\"runAsGroup\":1000,\"fsGroup\":1000},\"containers\":[{\"name\":\"snapshot-inspect-drill\",\"image\":\"$OPENBAO_IMAGE\",\"command\":[\"sh\",\"-c\",\"f=\$(ls -1 /backups/openbao/raft-*.snap | sort | tail -n 1); [ -n \\\"\$f\\\" ] && bao operator raft snapshot inspect \\\"\$f\\\"\"],\"volumeMounts\":[{\"name\":\"backups\",\"mountPath\":\"/backups\",\"readOnly\":true}]}],\"volumes\":[{\"name\":\"backups\",\"persistentVolumeClaim\":{\"claimName\":\"backups-k8s\"}}]}}" >/dev/null 2>&1; then
  log "newest raft snapshot inspects cleanly — OK"
else
  err "newest raft snapshot failed inspection (or none exists)"
fi

if [ "$failures" -ne 0 ]; then
  echo "[cluster-drill] FAILED with $failures error(s)" >&2
  exit 1
fi
log "all checks passed"
