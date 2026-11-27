# ArgoCD delete guard (ValidatingAdmissionPolicy)

**Date:** 2026-11-27
**PR:** [#494](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/494)

## What

`gitops/apps/platform/argocd/templates/delete-guard.yaml` adds a
`ValidatingAdmissionPolicy` + binding (`argocd-delete-guard`, action `Deny`).
It rejects `DELETE` of:

| Kind | Why |
|---|---|
| CustomResourceDefinition | cascade-deletes every custom resource of that type (Certificates, ExternalSecrets, CNPG Clusters, ...) |
| PersistentVolumeClaim / PersistentVolume | deletes volume data (backups, Plex media mounts, Grafana, ...) |
| Namespace | deletes everything inside |

It only applies when the requester is
`system:serviceaccount:argocd:argocd-application-controller`. That SA
performs sync prunes and cascade deletes for Applications. Humans, CI, and
the argocd-server UI/API delete normally.

To let ArgoCD delete one specific object, label it first:

```bash
kubectl label pvc -n <ns> <name> chalupa.tech/allow-argocd-delete=true
```

## Why

This is the prerequisite for `prune: true` on the platform, observability and
infra-tools ApplicationSets (follow-up PR). Those ran `prune: false` to avoid
cascade deletes. The side effect was that chart renames left orphans that
held apps OutOfSync forever. Deploy run 45825533099 failed Stage 4 on
`metallb` and `openbao` for this reason: renamed ClusterRoleBindings and a
ConfigMap, 10 orphans across 5 apps.

Blocking the few destructive kinds at the API server is simpler than either
leaving pruning off or keeping a list of safe kinds. Everything else prunes
normally. The `media` AppSet already runs `prune: true` with ArgoCD-tracked
PVCs (`media-plexmedia`, `readmebook-config`, ...), so this also closes an
existing gap.

An allowlist prune script in deploy Stage 4 (#493) was considered and closed
in favour of this: it was more code and needed per-kind upkeep.

## Behaviour to know

- **A blocked prune fails the sync** with a message naming the object and
  the label to use. The app goes `OutOfSync` / sync `Failed`, so it's visible.
  Nothing is deleted.
- **Removing an app directory** makes the ApplicationSet delete the
  Application, and its cascade delete stops at guarded objects. The
  Application stays in `Deleting`. Finish it by deleting or labelling those
  objects by hand. That's the intended point to decide whether the data goes.
- No app uses `Replace=true` / `Force=true` sync options or delete hooks, so
  routine syncs never hit the guard.

## Verification

- `helm template` + `kubeconform -strict` + `yamllint` pass.
- `kubectl apply --dry-run=server` against the live cluster (k8s v1.36)
  accepts the policy and compiles its CEL.
- After merge, check enforcement without deleting anything. Admission runs on
  server-side dry runs:

  ```bash
  SA=system:serviceaccount:argocd:argocd-application-controller
  kubectl delete pvc -n grafana grafana --dry-run=server --as=$SA            # denied
  kubectl delete ns metallb --dry-run=server --as=$SA                        # denied
  kubectl delete crd certificates.cert-manager.io --dry-run=server --as=$SA  # denied
  kubectl delete pvc -n grafana grafana --dry-run=server                     # allowed (you)
  kubectl delete cm -n metallb metallb-frr-startup --dry-run=server --as=$SA # allowed (not guarded)
  ```
