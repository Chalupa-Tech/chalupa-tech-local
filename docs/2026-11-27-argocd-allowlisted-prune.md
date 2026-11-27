# Allowlisted pruning of ArgoCD orphans in deploy Stage 4

**Date:** 2026-11-27
**PR:** TBD

## What

- New `scripts/k8s/prune-orphans.sh` (+ `scripts/k8s/tests/test_prune_orphans.sh`).
  It deletes resources that ArgoCD marks `requiresPruning` (the chart no longer
  renders them), but only kinds on a fixed allowlist, and only when nothing
  live still uses them:

  | Kind | Pruned unless |
  |---|---|
  | RoleBinding / ClusterRoleBinding | (pruned first so the role checks see the result) |
  | Role / ClusterRole | any remaining binding references it |
  | ServiceAccount | any pod runs as it |
  | ConfigMap | any pod mounts it or references it via env/envFrom/projected volume |

  Every candidate must also carry an `argocd.argoproj.io/tracking-id` naming
  the owning app. All other kinds (CRDs, PVCs, Secrets, Services, workloads)
  are never deleted. They show up as `::warning::` annotations on the run for
  a human to handle. Apps with deletions get a `refresh=normal` annotation so
  ArgoCD re-compares right away.
- `deploy.yml` Stage 4 runs it right before **Verify GitOps reconciliation**.
  The script is also added to the `argocd_bootstrap` path filter.

## Why

Deploy run 45825533099 failed Stage 4 because `metallb` and `openbao` stayed
OutOfSync (and Healthy) past the 5-minute verify timeout. They weren't
drifting. They held leftovers from chart renames that auto-sync never
removes, because the platform, observability and infra-tools ApplicationSets
use `prune: false`:

| App | Orphan | Replaced by |
|---|---|---|
| openbao | ClusterRoleBinding `openbao-server-binding`, `openbao-agent-injector-binding` | `openbao-openbao-*-binding` (identical roleRef + subjects) |
| metallb | ConfigMap `metallb-frr-startup` (chart 0.15.3) | `metallb-frr-k8s-frr-startup`, mounted by all frr-k8s pods |
| argocd | SA/Role/RoleBinding `argocd-redis-secret-init` | none needed. One-shot job that created the `argocd-redis` Secret (which has no ownerRef and stays) |
| grafana | Role/RoleBinding `grafana` (Role has no rules) | `grafana-clusterrole` |
| cert-manager | Role/RoleBinding `cert-manager-tokenrequest` | none needed. Only used by issuers with `serviceAccountRef`, and the only issuer is ACME `letsencrypt-prod` |

Before choosing this approach, each orphan was checked against live
workloads: no mounts, no pods running as them, duplicate bindings, and no
owner references or finalizers. Deleting them doesn't restart anything.

## Why not `prune: true`

`prune: false` on the platform tiers is deliberate. If a chart drops or renames
a CRD, a full prune would delete the CRD and cascade-delete every custom
resource of that type (cert-manager Certificates, ESO ExternalSecrets, CNPG
Clusters, ...). The allowlist covers the common, harmless case (renamed RBAC
and config) and leaves anything that holds data for a human.

## Verification

- `bash scripts/k8s/tests/test_prune_orphans.sh`: 9 cases (allowlist, never
  other kinds, mounted CM, in-use SA, bound role, binding-then-role ordering,
  foreign/missing tracking-id, dry-run, no-op).
- `scripts/k8s/prune-orphans.sh --dry-run` against the live cluster on
  2026-11-27 lists exactly the 10 orphans above, with 0 skipped.
- To preview locally: `KUBECONFIG=~/.kube/chalupa-cluster.yaml bash scripts/k8s/prune-orphans.sh --dry-run`.
