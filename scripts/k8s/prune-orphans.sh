#!/usr/bin/env bash
# Delete ArgoCD orphans (status.resources[].requiresPruning) of low-risk kinds.
#
# The platform/observability/infra-tools ApplicationSets run prune:false so a
# chart that drops a CRD can't cascade-delete its custom resources. The cost:
# when a chart renames a resource, the old copy lingers and holds the app
# OutOfSync forever (e.g. openbao 0.30 renamed its ClusterRoleBindings).
#
# This prunes only kinds whose deletion can't take data with it, and only when
# nothing live still uses them:
#   RoleBinding / ClusterRoleBinding  pruned first, so role checks see the result
#   Role / ClusterRole                skipped if any binding still references it
#   ServiceAccount                    skipped if any pod runs as it
#   ConfigMap                         skipped if any pod mounts/references it
# Every other kind (CRDs, PVCs, Secrets, Services, workloads) is reported as a
# CI warning and left for a human. Each candidate must also carry an ArgoCD
# tracking-id naming the owning app.
#
# Usage: prune-orphans.sh [--dry-run]
set -euo pipefail

dry_run=0
[ "${1:-}" = "--dry-run" ] && dry_run=1
ARGOCD_NS=${ARGOCD_NS:-argocd}
RBAC=rbac.authorization.k8s.io

# app <TAB> group <TAB> kind <TAB> namespace <TAB> name; "-" for empty fields so
# `read` doesn't collapse adjacent tabs.
orphans=$(kubectl -n "$ARGOCD_NS" get applications -o json | jq -r '
  .items[] | .metadata.name as $app | .status.resources[]?
  | select(.requiresPruning == true)
  | def dash: if . == null or . == "" then "-" else . end;
    [$app, (.group | dash), .kind, (.namespace | dash), .name] | @tsv')

if [ -z "$orphans" ]; then
  echo "No ArgoCD orphans awaiting prune."
  exit 0
fi

ref() { # group kind name -> kubectl resource ref
  if [ "$1" = "-" ]; then echo "$2/$3"; else echo "$2.$1/$3"; fi
}

# Bindings pruned earlier in this run (or that would be, under --dry-run) don't
# count as live references to a role.
# shellcheck disable=SC2016 # jq program, not shell
LIVE='def live: ("\(.kind)/\(.metadata.namespace // "-")/\(.metadata.name)" as $k
  | ($gone | split(" ") | index($k)) == null);'
gone=""

in_use() { # group kind ns name -> prints reason and returns 0 if still used
  local group=$1 kind=$2 ns=$3 name=$4 n=0
  case "$group/$kind" in
    -/ConfigMap)
      n=$(kubectl -n "$ns" get pods -o json | jq --arg n "$name" '
        [.items[].spec | .. | objects
         | (.configMap?.name, .configMapRef?.name, .configMapKeyRef?.name)
         | select(. == $n)] | length')
      [ "$n" -gt 0 ] && echo "referenced by $n pod volume/env entries" ;;
    -/ServiceAccount)
      n=$(kubectl -n "$ns" get pods -o json | jq --arg n "$name" '
        [.items[] | select(.spec.serviceAccountName == $n)] | length')
      [ "$n" -gt 0 ] && echo "used by $n pods" ;;
    "$RBAC"/Role)
      n=$(kubectl -n "$ns" get rolebindings -o json | jq --arg n "$name" --arg gone "$gone" "$LIVE"'
        [.items[] | select(live and .roleRef.kind == "Role" and .roleRef.name == $n)] | length')
      [ "$n" -gt 0 ] && echo "bound by $n RoleBindings" ;;
    "$RBAC"/ClusterRole)
      n=$( { kubectl get rolebindings -A -o json; kubectl get clusterrolebindings -o json; } \
        | jq -s --arg n "$name" --arg gone "$gone" "$LIVE"'
          [.[].items[] | select(live and .roleRef.kind == "ClusterRole" and .roleRef.name == $n)] | length')
      [ "$n" -gt 0 ] && echo "bound by $n bindings" ;;
  esac
  [ "$n" -gt 0 ]
}

pruned_apps=""
pruned=0
skipped=0
for phase in bindings roles other; do
  while IFS=$'\t' read -r app group kind ns name; do
    case "$group/$kind" in
      "$RBAC"/RoleBinding|"$RBAC"/ClusterRoleBinding) [ $phase = bindings ] || continue ;;
      "$RBAC"/Role|"$RBAC"/ClusterRole) [ $phase = roles ] || continue ;;
      -/ServiceAccount|-/ConfigMap) [ $phase = other ] || continue ;;
      *)
        [ $phase = other ] || continue
        echo "::warning::$app: orphan $kind $ns/$name is not on the prune allowlist; delete it by hand if it is truly unused"
        skipped=$((skipped + 1))
        continue ;;
    esac

    r=$(ref "$group" "$kind" "$name")
    nsa=""
    [ "$ns" = "-" ] || nsa="--namespace=$ns"
    # shellcheck disable=SC2086 # $nsa is empty or one word
    tracking=$(kubectl get "$r" $nsa --ignore-not-found \
      -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}')
    if [ "${tracking%%:*}" != "$app" ]; then
      echo "::warning::$app: skip $kind $ns/$name: tracking-id '${tracking}' does not belong to $app"
      skipped=$((skipped + 1))
      continue
    fi
    if reason=$(in_use "$group" "$kind" "$ns" "$name"); then
      echo "::warning::$app: skip $kind $ns/$name: still $reason"
      skipped=$((skipped + 1))
      continue
    fi

    gone="$gone $kind/$ns/$name"
    pruned=$((pruned + 1))
    if [ $dry_run = 1 ]; then
      echo "$app: would prune $kind $ns/$name"
    else
      echo "$app: pruning $kind $ns/$name"
      # shellcheck disable=SC2086
      kubectl delete "$r" $nsa --ignore-not-found --wait=false
      pruned_apps="$pruned_apps $app"
    fi
  done <<< "$orphans"
done

# Ask ArgoCD to re-compare now rather than on its next poll.
# shellcheck disable=SC2086 # intentional word split of the app list
for app in $(printf '%s\n' $pruned_apps | sort -u); do
  kubectl -n "$ARGOCD_NS" annotate application "$app" \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null
done
echo "Done. pruned=$pruned skipped=$skipped dry_run=$dry_run"
