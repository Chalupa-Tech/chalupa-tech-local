# Turn on prune for platform, observability and infra-tools ApplicationSets

**Date:** 2026-11-27
**PR:** [#495](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/495)

## What

Set `syncPolicy.automated.prune: true` in
`gitops/bootstrap/applicationsets/{platform,observability,infra-tools}.yaml`.
All five ApplicationSets and the root app now prune.

## Why

With `prune: false`, a chart that renames a resource leaves the old copy
behind, and the app stays OutOfSync forever. Deploy run 45825533099 failed
Stage 4 on `metallb` and `openbao` because of this. The first prune after
merge removes these 10 orphans, each checked against the live cluster
(nothing uses them, no ownerRefs or finalizers):

| App | Orphans |
|---|---|
| openbao | ClusterRoleBinding `openbao-server-binding`, `openbao-agent-injector-binding` (duplicates of `openbao-openbao-*`) |
| metallb | ConfigMap `metallb-frr-startup` (replaced by `metallb-frr-k8s-frr-startup`) |
| argocd | SA/Role/RoleBinding `argocd-redis-secret-init` |
| grafana | Role/RoleBinding `grafana` (empty Role) |
| cert-manager | Role/RoleBinding `cert-manager-tokenrequest` (no `serviceAccountRef` issuers) |

`prune: false` existed to stop cascade deletes. The argocd-delete-guard
admission policy (#494, `docs/2026-11-27-argocd-delete-guard.md`) now covers
that risk at the API server by blocking ArgoCD from deleting CRDs, PVCs, PVs
and Namespaces. **This must merge after #494 is Synced.**

## Verification

- Before merge: `kubectl -n argocd get app -o json | jq '.items[].status.resources[]? | select(.requiresPruning)'`
  lists only the 10 objects above.
- After merge: all apps are Synced, and the next deploy's Stage 4 verify passes.
