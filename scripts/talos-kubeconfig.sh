#!/usr/bin/env bash
# Fetch the chalupa-cluster kubeconfig from a Talos control-plane node.
#
# Usage:
#   ./scripts/talos-kubeconfig.sh                      # writes ~/.kube/chalupa-cluster.yaml
#   ./scripts/talos-kubeconfig.sh /tmp/kubeconfig      # custom output path
#   NODE=192.168.1.228 ./scripts/talos-kubeconfig.sh   # pin to a specific CP node
#
# How node/endpoint discovery works:
#   - Reads the active talosconfig (`talosctl config info`) for nodes + endpoints.
#   - Queries cluster membership (`talosctl get members`) to find which nodes
#     are controlplane and picks the first. `talosctl kubeconfig` only accepts
#     a single node, so a worker would be rejected.
#   - Override CONTEXT, NODE, or ENDPOINTS via env vars to bypass discovery.
#
# Requires: talosctl, jq.
set -euo pipefail

CONTEXT="${CONTEXT:-chalupa-cluster}"
OUT="${1:-$HOME/.kube/chalupa-cluster.yaml}"

info=$(talosctl --context "$CONTEXT" config info)

nodes_raw=$(awk -F': +' '/^Nodes:/{print $2}' <<<"$info")
endpoints_raw=$(awk -F': +' '/^Endpoints:/{print $2}' <<<"$info")

ENDPOINTS="${ENDPOINTS:-$(echo "$endpoints_raw" | tr -d ' ')}"
first_node=$(echo "$nodes_raw" | tr ',' '\n' | head -1 | xargs)

if [[ -z "$ENDPOINTS" || -z "$first_node" ]]; then
  echo "ERROR: talosconfig for context '$CONTEXT' is missing nodes or endpoints" >&2
  exit 1
fi

if [[ -z "${NODE:-}" ]]; then
  echo "==> Discovering control-plane node via $first_node (endpoints: $ENDPOINTS)"
  NODE=$(
    talosctl --context "$CONTEXT" --endpoints "$ENDPOINTS" --nodes "$first_node" \
      get members -o json \
    | jq -rs '
        [.[] | select(.spec.machineType=="controlplane") | .spec.addresses[0]]
        | .[0] // empty
      '
  )
fi

if [[ -z "$NODE" ]]; then
  echo "ERROR: could not discover a control-plane node from cluster members" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
echo "==> Fetching kubeconfig from $NODE (endpoints $ENDPOINTS) -> $OUT"
talosctl --context "$CONTEXT" \
  --nodes "$NODE" \
  --endpoints "$ENDPOINTS" \
  kubeconfig --force "$OUT"

echo "==> Done. Use it with:"
echo "    export KUBECONFIG=$OUT"
echo "    kubectl get nodes"
