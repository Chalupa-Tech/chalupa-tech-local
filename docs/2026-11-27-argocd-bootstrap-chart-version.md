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
