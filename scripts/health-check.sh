#!/usr/bin/env bash
# Estate health check, run from a CI runner that is on the tailnet with the
# pve1 SSH key loaded and KUBECONFIG exported. Every check prints exactly one
# line — `ok <name>` or `FAIL <name>: <reason>` — and all checks run even
# after a failure, so one run gives the whole picture. Exit 1 if any failed.
#
# Used after the maintenance window (reboot of pve1) and on demand.
set -uo pipefail

HC_PVE="${HC_PVE:-192.168.1.223}"
HC_PLEX_URL="${HC_PLEX_URL:-http://192.168.1.224:32400/identity}"
HC_HA_URL="${HC_HA_URL:-http://192.168.1.234:8123/}"
HC_TRUENAS="${HC_TRUENAS:-192.168.1.40}"
HC_GUESTS="${HC_GUESTS:-100 101 200 250}"
HC_NODE_COUNT="${HC_NODE_COUNT:-6}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes)

failed=0
ok()   { echo "ok $1"; }
bad()  { echo "FAIL $1: $2"; failed=1; }

check_pve_ssh() {
  if ssh "${SSH_OPTS[@]}" "root@$HC_PVE" true 2>/dev/null; then ok pve-ssh; else bad pve-ssh "ssh root@$HC_PVE failed"; fi
}

check_guests_running() {
  # `qm list` columns: VMID NAME STATUS ...; `pct list`: VMID Status Lock Name.
  local vms cts missing="" id state
  vms=$(ssh "${SSH_OPTS[@]}" "root@$HC_PVE" "qm list" 2>/dev/null | awk 'NR > 1 {print $1, $3}')
  cts=$(ssh "${SSH_OPTS[@]}" "root@$HC_PVE" "pct list" 2>/dev/null | awk 'NR > 1 {print $1, $2}')
  for id in $HC_GUESTS; do
    state=$(awk -v id="$id" '$1 == id {print $2; exit}' <<<"$vms"$'\n'"$cts")
    [ "$state" = running ] || missing+="$id(${state:-absent}) "
  done
  if [ -z "$missing" ]; then ok guests-running; else bad guests-running "${missing% } not running"; fi
}

check_talos_nodes_ready() {
  local json notready count
  json=$(kubectl get nodes -o json 2>/dev/null) || { bad talos-nodes-ready "kubectl get nodes failed"; return; }
  notready=$(jq -r '.items[] | select((.status.conditions[] | select(.type=="Ready") | .status) != "True") | .metadata.name' <<<"$json" | paste -sd' ' -)
  count=$(jq '.items | length' <<<"$json")
  if [ -n "$notready" ]; then bad talos-nodes-ready "$notready NotReady"
  elif [ "$count" != "$HC_NODE_COUNT" ]; then bad talos-nodes-ready "$count nodes, expected $HC_NODE_COUNT"
  else ok talos-nodes-ready; fi
}

check_argocd_healthy() {
  local json unhealthy
  json=$(kubectl -n argocd get applications -o json 2>/dev/null) || { bad argocd-healthy "kubectl get applications failed"; return; }
  unhealthy=$(jq -r '.items[] | select(.status.health.status != "Healthy") | "\(.metadata.name)=\(.status.health.status)"' <<<"$json" | paste -sd' ' -)
  if [ -z "$unhealthy" ]; then ok argocd-healthy; else bad argocd-healthy "$unhealthy"; fi
}

check_openbao_unsealed() {
  local pod sealed bad_pods=""
  for pod in openbao-0 openbao-1 openbao-2; do
    sealed=$(kubectl -n openbao exec "$pod" -- bao status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null)
    [ "$sealed" = false ] || bad_pods+="$pod(${sealed:-unreachable}) "
  done
  if [ -z "$bad_pods" ]; then ok openbao-unsealed; else bad openbao-unsealed "${bad_pods% }sealed"; fi
}

check_externalsecrets_ready() {
  local json notready
  json=$(kubectl get externalsecret -A -o json 2>/dev/null) || { bad externalsecrets-ready "kubectl get externalsecret failed"; return; }
  notready=$(jq -r '.items[] | select(((.status.conditions // [])[] | select(.type=="Ready") | .status) != "True") | "\(.metadata.namespace)/\(.metadata.name)"' <<<"$json" | paste -sd' ' -)
  if [ -z "$notready" ]; then ok externalsecrets-ready; else bad externalsecrets-ready "$notready not Ready"; fi
}

check_plex_identity() {
  if curl -fsS --max-time 15 "$HC_PLEX_URL" >/dev/null 2>&1; then ok plex-identity; else bad plex-identity "$HC_PLEX_URL unreachable"; fi
}

check_ha_http() {
  local code
  code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "$HC_HA_URL" 2>/dev/null)
  case "$code" in 200|30[0-9]|401) ok ha-http ;; *) bad ha-http "$HC_HA_URL returned '${code:-none}'" ;; esac
}

check_truenas_nfs() {
  # shellcheck disable=SC2029  # client-side expansion of $HC_TRUENAS is intended
  if ssh "${SSH_OPTS[@]}" "root@$HC_PVE" "showmount -e $HC_TRUENAS" 2>/dev/null | grep -q '/mnt/PlexMedia/frame'; then ok truenas-nfs; else bad truenas-nfs "showmount -e $HC_TRUENAS does not list /mnt/PlexMedia/frame"; fi
}

check_pve_ssh
check_guests_running
check_talos_nodes_ready
check_argocd_healthy
check_openbao_unsealed
check_externalsecrets_ready
check_plex_identity
check_ha_http
check_truenas_nfs

if [ "$failed" -ne 0 ]; then echo "health-check: FAILED"; exit 1; fi
echo "health-check: all checks passed"
