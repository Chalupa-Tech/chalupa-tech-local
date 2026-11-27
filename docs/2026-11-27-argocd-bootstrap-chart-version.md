# ArgoCD bootstrap uses the self-managed chart version

**Date:** 2026-11-27
**PR:** [#498](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/498)

## What

- `deploy.yml` Stage 4 *Install ArgoCD (bootstrap)* now reads the `argo-cd`
  chart version from `gitops/apps/platform/argocd/Chart.yaml` with `yq`, instead
  of a hardcoded `--version 9.7.1`. If the dependency can't be found, the step
  fails with an error rather than installing an unpinned chart.
- Removed the Renovate regex manager that bumped the separate pin in
  `deploy.yml`. The wrapper chart's `argo-cd` dependency, bumped by the
  `helmv3` manager in the "platform charts" group, is now the only version.

## Why

The two pins drifted. The wrapper chart moved to `argo-cd` 10.14.0 (ArgoCD
v3.6.1) in #424, but the bootstrap pin's separate Renovate PRs stopped at 9.7.1
(#462). On 2026-11-27 the live Helm release was at revision 109 with
`argo-cd-9.7.1` / v3.4.4. So every deploy that ran Stage 4 ran
`helm upgrade` *down* two ArgoCD minor versions, and then ArgoCD's self-managed
app upgraded itself back. That's an avoidable rollback of the CD controller
on every run, and a 9.x → 10.x chart downgrade risks CRD or config skew in
between.

## Verification

- `helm template argo/argo-cd --version 10.14.0 -f .github/argocd-bootstrap-values.yaml`
  renders cleanly (the bootstrap values are minimal and still valid on 10.x).
- `scripts/renovate/validate.sh` passes; `actionlint` reports no new findings.
- After the next Stage 4 run: the step log shows `Bootstrapping argo-cd chart 10.14.0`,
  and `helm -n argocd list` shows `argo-cd-10.14.0`.

## Follow-up: bootstrap only on a fresh cluster ([#499](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/499))

The first deploy after #498 (run
[46070669131](https://github.com/Chalupa-Tech/chalupa-tech-local/actions/runs/46070669131))
read the version correctly (`Bootstrapping argo-cd chart 10.14.0`), but Stage 4
then failed:

```
UPGRADE FAILED: NetworkPolicy "argocd-application-controller" in namespace "argocd" exists and
cannot be imported into the current release: invalid ownership metadata; missing key "meta.helm.sh/release-name"
```

Chart 10.x adds NetworkPolicies, which the self-managed `argocd` Application had
already created without Helm ownership annotations. The 9.7.1 pin only hid the
underlying problem: Stage 4 ran `helm upgrade` against an ArgoCD that manages
itself, so Helm and ArgoCD both owned the same objects. Helm rejected the
upgrade before changing anything, and the cluster stayed on v3.6.1, healthy.

The fix is that Stage 4 skips the helm step when `Application argocd` exists.
Helm installs ArgoCD only on a fresh cluster, and after that ArgoCD manages
itself through `gitops/apps/platform/argocd`. The `argocd` Helm release
(rev 109, `argo-cd-9.7.1`) stays as stale metadata. Nothing reads it, and
`helm -n argocd list` will keep showing 9.7.1.
