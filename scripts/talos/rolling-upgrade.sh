#!/usr/bin/env bash
# Rolling Talos (and Kubernetes) upgrade with health gates and rollback.
# Runs from CI (deploy.yml Stage 2c) or a workstation with TALOSCONFIG and
# KUBECONFIG set.
#
#   rolling-upgrade.sh --talos-version v1.14.5 --k8s-version 1.36.0 \
#       --schematic <factory schematic id> [--nodes-cp "ip ip ip"] [--nodes-worker "ip ip ip"]
#
# Order: pre-flight (nodes Ready, OpenBao all unsealed — a sealed replica
# makes the openbao PDB block the drain), etcd snapshot, control planes one
# at a time, then workers one at a time. Per node: skip if already at the
# target, `talosctl upgrade --preserve --wait`, then gate on node Ready +
# etcd status + ArgoCD argocd/traefik Healthy + ClusterSecretStore Ready
# (re-unsealing the replica that restarted when unseal keys are available).
# Gate timeout -> `talosctl rollback` for that node, stop, exit 1; the
# remaining nodes are never touched. Finally `talosctl upgrade-k8s --to` the
# repo's pinned Kubernetes version — never a Talos default — if it differs.
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
first_cp=${nodes_cp%% *}
image="factory.talos.dev/installer/${schematic}:${talos_version}"

log() { printf '[talos-upgrade] %s\n' "$*"; }
die() { printf '[talos-upgrade] ERROR: %s\n' "$*" >&2; exit 1; }

node_version() { talosctl -n "$1" version 2>/dev/null | awk '/^Server:/{s=1} s && /Tag:/{print $2; exit}'; }
k8s_running() { kubectl get nodes -o json | jq -r '[.items[].status.nodeInfo.kubeletVersion] | sort | .[0]' | sed 's/^v//'; }
nodes_all_ready() { kubectl get nodes -o json | jq -e 'all(.items[]; any(.status.conditions[]; .type == "Ready" and .status == "True"))' >/dev/null 2>&1; }
apps_healthy() { kubectl -n argocd get applications argocd traefik -o json | jq -e 'all(.items[]; .status.health.status == "Healthy")' >/dev/null 2>&1; }
store_ready() { [ "$(kubectl get clustersecretstore openbao -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; }
etcd_ok() { talosctl -n "$first_cp" etcd status >/dev/null 2>&1; }
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
ensure_unsealed() {  # returns 0 when every replica is unsealed (after trying the helper)
  local sealed
  sealed=$(sealed_pods)
  [ -z "$sealed" ] && return 0
  if [ -n "${OPENBAO_UNSEAL_KEYS:-}" ]; then
    log "unsealing $sealed via unseal-ci"
    bash "$UNSEAL_CI" || true
    sealed=$(sealed_pods)
    [ -z "$sealed" ] && return 0
  fi
  log "OpenBao replica(s) sealed: $sealed"
  return 1
}

# ------------------------------------------------------------------ plan
pending=()
for ip in $nodes_cp $nodes_worker; do
  cur=$(node_version "$ip")
  if [ "$cur" = "$talos_version" ]; then echo "node $ip: skipped (already $cur)"; else pending+=("$ip"); fi
done
k8s_now=$(k8s_running)
if [ ${#pending[@]} -eq 0 ] && [ "$k8s_now" = "$k8s_version" ]; then
  log "nothing to do: all nodes at $talos_version, Kubernetes at $k8s_version"
  exit 0
fi

# ------------------------------------------------------------- pre-flight
nodes_all_ready || die "pre-flight: not all nodes Ready"
etcd_ok || die "pre-flight: etcd status failed"
ensure_unsealed || die "pre-flight: a sealed OpenBao replica would block the drain (openbao PDB); unseal it or provide OPENBAO_UNSEAL_KEYS"
log "etcd snapshot -> $ETCD_SNAPSHOT_PATH"
talosctl -n "$first_cp" etcd snapshot "$ETCD_SNAPSHOT_PATH"

# ------------------------------------------------------------ per node
gate() {  # <ip> -> 0 when healthy within the gate window
  local i
  for ((i = 1; i <= GATE_ATTEMPTS; i++)); do
    if [ "$(node_version "$1")" = "$talos_version" ] && nodes_all_ready && etcd_ok && apps_healthy && ensure_unsealed && store_ready; then
      return 0
    fi
    [ "$i" -lt "$GATE_ATTEMPTS" ] && sleep "$GATE_SLEEP"
  done
  return 1
}

for ip in "${pending[@]}"; do
  log "node $ip: upgrading to $talos_version ($image)"
  if ! talosctl -n "$ip" upgrade --image "$image" --preserve --wait --timeout 15m; then
    log "node $ip: upgrade command failed; rolling back"
    talosctl -n "$ip" rollback || true
    echo "node $ip: FAILED (rolled back)"; exit 1
  fi
  if gate "$ip"; then
    echo "node $ip: upgraded"
  else
    log "node $ip: health gate not met within $((GATE_ATTEMPTS * GATE_SLEEP))s; rolling back"
    talosctl -n "$ip" rollback || true
    echo "node $ip: FAILED (rolled back)"; exit 1
  fi
done

# ------------------------------------------------------------ kubernetes
if [ "$k8s_now" != "$k8s_version" ]; then
  log "Kubernetes $k8s_now -> $k8s_version (repo pin)"
  talosctl -n "$first_cp" upgrade-k8s --to "$k8s_version"
  nodes_all_ready || die "nodes not Ready after upgrade-k8s"
  echo "kubernetes: upgraded to $k8s_version"
fi
log "done"
