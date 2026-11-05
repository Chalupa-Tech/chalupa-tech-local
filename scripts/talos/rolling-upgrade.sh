#!/usr/bin/env bash
# Rolling Talos (and Kubernetes) upgrade with health gates and rollback.
# Runs from CI (deploy.yml Stage 2c) or a workstation with TALOSCONFIG and
# KUBECONFIG set.
#
#   rolling-upgrade.sh --talos-version v1.14.5 --k8s-version 1.36.0 \
#       --schematic <factory schematic id> [--nodes-cp "ip ip ip"] [--nodes-worker "ip ip ip"]
#
# Order: pre-flight (nodes Ready, etcd quorum on all control planes, every
# OpenBao replica unsealed — a sealed one makes the openbao PDB block the
# drain), etcd snapshot, control planes one at a time, then workers one at a
# time. Before each node the OpenBao check repeats: a drain restarts the
# replica that lived on the node; with OCI KMS auto-unseal it comes back
# unsealed within the UNSEAL_WAIT window (2 min), with OPENBAO_UNSEAL_KEYS
# (Shamir, pre-migration) it is unsealed by the helper, otherwise the run
# STOPS cleanly before the next node (exit 1, nothing rolled back, cluster
# healthy but partially upgraded — re-run after unsealing).
#
# Per node: skip if already at the target; `talosctl upgrade --preserve
# --wait`; then the gate: node reports the target version, all nodes Ready,
# etcd healthy on all control planes, ArgoCD argocd/traefik Healthy,
# ClusterSecretStore Ready. Rollback (`talosctl rollback`) happens ONLY when
# the node is confirmed booted into the new version and the gate still
# fails: a node that never left the old version (upgrade command error,
# drain blocked, VIP reconnect) is left alone and uncordoned — rolling back
# the A/B partition of an un-upgraded node would regress it. Either failure
# stops the run; later nodes are never touched.
#
# Finally `talosctl upgrade-k8s --to` the repo's pinned Kubernetes version —
# never a Talos default, and never a downgrade.
set -euo pipefail

talos_version="" k8s_version="" schematic=""
nodes_cp="192.168.1.225 192.168.1.228 192.168.1.229"
nodes_worker="192.168.1.226 192.168.1.227 192.168.1.232"
while [ $# -gt 0 ]; do
  case "$1" in
    --talos-version) talos_version=$2; shift 2 ;;
    --k8s-version) k8s_version=$2; shift 2 ;;
    --schematic) schematic=$2; shift 2 ;;
    --nodes-cp) nodes_cp=$2; shift 2 ;;
    --nodes-worker) nodes_worker=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
for v in talos_version k8s_version schematic; do [ -n "${!v}" ] || { echo "--${v//_/-} is required" >&2; exit 2; }; done

GATE_ATTEMPTS="${GATE_ATTEMPTS:-40}"      # x GATE_SLEEP = 10 min
GATE_SLEEP="${GATE_SLEEP:-15}"
UNSEAL_CI="${UNSEAL_CI:-$(dirname "$0")/../openbao/unseal-ci.sh}"
ETCD_SNAPSHOT_PATH="${ETCD_SNAPSHOT_PATH:-/tmp/etcd-pre-upgrade.snap}"
UNSEAL_WAIT_ATTEMPTS="${UNSEAL_WAIT_ATTEMPTS:-8}"   # x UNSEAL_WAIT_SLEEP = 2 min
UNSEAL_WAIT_SLEEP="${UNSEAL_WAIT_SLEEP:-15}"
first_cp=${nodes_cp%% *}
cp_list=${nodes_cp// /,}
cp_count=$(wc -w <<<"$nodes_cp" | tr -d ' ')
image="factory.talos.dev/installer/${schematic}:${talos_version}"

log() { printf '[talos-upgrade] %s\n' "$*"; }
die() { printf '[talos-upgrade] ERROR: %s\n' "$*" >&2; exit 1; }

node_version() { talosctl -n "$1" version 2>/dev/null | awk '/^Server:/{s=1} s && /Tag:/{print $2; exit}' || true; }
node_name() { kubectl get nodes -o json 2>/dev/null | jq -r --arg ip "$1" '.items[] | select(any(.status.addresses[]; .type == "InternalIP" and .address == $ip)) | .metadata.name' | head -n 1; }
k8s_running() { kubectl get nodes -o json | jq -r '[.items[].status.nodeInfo.kubeletVersion] | sort | .[0]' | sed 's/^v//'; }
nodes_all_ready() { kubectl get nodes -o json 2>/dev/null | jq -e 'all(.items[]; any(.status.conditions[]; .type == "Ready" and .status == "True"))' >/dev/null 2>&1; }
apps_healthy() { kubectl -n argocd get applications argocd traefik -o json 2>/dev/null | jq -e 'all(.items[]; .status.health.status == "Healthy")' >/dev/null 2>&1; }
store_ready() { [ "$(kubectl get clustersecretstore openbao -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; }
# etcd healthy = every control plane answers `etcd status` (one member line each)
etcd_ok() {
  local lines
  lines=$(talosctl -n "$cp_list" etcd status 2>/dev/null | awk 'NR > 1 && NF > 0' | wc -l | tr -d ' ')
  [ "$lines" -ge "$cp_count" ]
}
sealed_pods() {
  local pod out list=""
  for pod in openbao-0 openbao-1 openbao-2; do
    set +o pipefail
    out=$(kubectl -n openbao exec "$pod" -- bao status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null)
    set -o pipefail
    [ "$out" = false ] || list+="$pod "
  done
  echo "${list% }"
}
# ensure_unsealed: 0 when every replica is unsealed. A replica that was just
# rescheduled (drain, reboot) auto-unseals through OCI KMS a few seconds
# after it starts, so a sealed one is polled UNSEAL_WAIT_ATTEMPTS times,
# UNSEAL_WAIT_SLEEP apart, before it counts as stuck. Shamir shares in
# OPENBAO_UNSEAL_KEYS (pre-migration clusters) are tried first.
ensure_unsealed() {
  local sealed i
  sealed=$(sealed_pods)
  [ -z "$sealed" ] && return 0
  if [ -n "${OPENBAO_UNSEAL_KEYS:-}" ]; then
    log "unsealing $sealed via unseal-ci"
    bash "$UNSEAL_CI" || true
    sealed=$(sealed_pods)
    [ -z "$sealed" ] && return 0
  fi
  log "OpenBao replica(s) sealed: $sealed; waiting up to $((UNSEAL_WAIT_ATTEMPTS * UNSEAL_WAIT_SLEEP))s for auto-unseal"
  for ((i = 1; i <= UNSEAL_WAIT_ATTEMPTS; i++)); do
    sleep "$UNSEAL_WAIT_SLEEP"
    sealed=$(sealed_pods)
    [ -z "$sealed" ] && { log "all OpenBao replicas unsealed"; return 0; }
  done
  log "OpenBao replica(s) still sealed: $sealed"
  return 1
}
version_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]; }

# ------------------------------------------------------------------ plan
pending=()
for ip in $nodes_cp $nodes_worker; do
  cur=$(node_version "$ip")
  [ -n "$cur" ] || die "cannot read the Talos version of $ip"
  if [ "$cur" = "$talos_version" ]; then echo "node $ip: skipped (already $cur)"; else pending+=("$ip"); fi
done
k8s_now=$(k8s_running)
[ -n "$k8s_now" ] || die "cannot read the running Kubernetes version"
need_k8s=0; version_lt "$k8s_now" "$k8s_version" && need_k8s=1
if [ ${#pending[@]} -eq 0 ] && [ "$need_k8s" -eq 0 ]; then
  log "nothing to do: all nodes at $talos_version, Kubernetes $k8s_now (pin $k8s_version)"
  exit 0
fi

# ------------------------------------------------------------- pre-flight
nodes_all_ready || die "pre-flight: not all nodes Ready"
etcd_ok || die "pre-flight: etcd status failed on a control plane"
ensure_unsealed || die "pre-flight: a sealed OpenBao replica would block the drain (openbao PDB); unseal it or provide OPENBAO_UNSEAL_KEYS"
if [ ${#pending[@]} -gt 0 ]; then
  log "etcd snapshot -> $ETCD_SNAPSHOT_PATH"
  talosctl -n "$first_cp" etcd snapshot "$ETCD_SNAPSHOT_PATH"
fi

# ------------------------------------------------------------ per node
# wait_version <ip>: 0 once the node reports the target version
wait_version() {
  local i
  for ((i = 1; i <= GATE_ATTEMPTS; i++)); do
    [ "$(node_version "$1")" = "$talos_version" ] && return 0
    [ "$i" -lt "$GATE_ATTEMPTS" ] && sleep "$GATE_SLEEP"
  done
  return 1
}
# gate: cluster-level health after a node came back on the new version
gate() {
  local i
  for ((i = 1; i <= GATE_ATTEMPTS; i++)); do
    if nodes_all_ready && etcd_ok && apps_healthy && store_ready; then return 0; fi
    [ "$i" -lt "$GATE_ATTEMPTS" ] && sleep "$GATE_SLEEP"
  done
  return 1
}

for ip in "${pending[@]}"; do
  # A sealed replica (from the previous node's drain) would block this drain.
  ensure_unsealed || { echo "stopped before $ip: a sealed OpenBao replica would block the drain — unseal it (or set OPENBAO_UNSEAL_KEYS) and re-run"; exit 1; }
  log "node $ip: upgrading to $talos_version ($image)"
  if ! talosctl -n "$ip" upgrade --image "$image" --preserve --wait --timeout 15m; then
    log "node $ip: upgrade command returned an error; checking what actually happened"
    if ! wait_version "$ip"; then
      # Still on the old version: nothing to roll back. Uncordon in case the drain happened.
      name=$(node_name "$ip"); [ -n "$name" ] && kubectl uncordon "$name" >/dev/null 2>&1 || true
      echo "node $ip: FAILED (still on $(node_version "$ip"); not rolled back, uncordoned)"; exit 1
    fi
    log "node $ip: reports $talos_version despite the error (connection drop); continuing with the gate"
  fi
  if ! wait_version "$ip"; then
    name=$(node_name "$ip"); [ -n "$name" ] && kubectl uncordon "$name" >/dev/null 2>&1 || true
    echo "node $ip: FAILED (never reported $talos_version; not rolled back)"; exit 1
  fi
  if gate; then
    echo "node $ip: upgraded"
  else
    log "node $ip: booted $talos_version but the cluster gate failed within $((GATE_ATTEMPTS * GATE_SLEEP))s; rolling back"
    talosctl -n "$ip" rollback || true
    echo "node $ip: FAILED (rolled back)"; exit 1
  fi
done

# ------------------------------------------------------------ kubernetes
if [ "$need_k8s" -eq 1 ]; then
  log "Kubernetes $k8s_now -> $k8s_version (repo pin)"
  talosctl -n "$first_cp" upgrade-k8s --to "$k8s_version"
  nodes_all_ready || die "nodes not Ready after upgrade-k8s"
  echo "kubernetes: upgraded to $k8s_version"
elif [ "$k8s_now" != "$k8s_version" ]; then
  log "Kubernetes $k8s_now is ahead of the pin $k8s_version — not downgrading; bump the pin"
fi
log "done"
