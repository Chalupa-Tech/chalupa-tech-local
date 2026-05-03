# ArgoCD Foundation — Design

**Date:** 2026-05-03
**Status:** Approved (pending implementation plan)
**Sub-project:** #1 of a multi-cycle ArgoCD/GitOps rollout

## Context

ArgoCD is currently bootstrapped on the Talos cluster via a single Helm install in `deploy.yml` Stage 4 (added in `2026-04-13-add-talos-cluster.md`). It runs, but no Applications or ApplicationSets exist — the GitOps loop is not yet wired.

The longer-term goal is to deploy a stack of services (Sonarr, Radarr, Seerr, NzbGet, Tdarr, Home Assistant + Z-Wave, plus platform services like cert-manager, Traefik, OpenBao) via GitOps, with backups across all of them. That goal spans multiple subsystems and was decomposed into a sequence of sub-projects (see "Roadmap" below). This document specifies **only sub-project #1**: the GitOps foundation plus the platform primitives (LoadBalancer, default StorageClass) that everything downstream will depend on.

## Roadmap (for context)

This sub-project is one of an ordered series:

1. **ArgoCD foundation** *(this spec)* — `gitops/` repo structure, ApplicationSets, ArgoCD self-management, MetalLB, local-path-provisioner.
2. **Secrets + TLS Ingress** — OpenBao (Raft, manual unseal), external-secrets-operator, cert-manager (Cloudflare DNS-01 + Let's Encrypt), Traefik with wildcard cert for `*.frame.chalupatech.com`.
3. **Media stack** — Sonarr, Radarr, Seerr, NzbGet, Tdarr (CPU transcoding) deployed via the bjw-s `app-template` chart, NFS-backed storage from existing TrueNAS shares.
4. **Home automation** — Home Assistant + Z-Wave in a new privileged LXC (Z-Wave USB passthrough; same pattern as the Plex LXC).
5. **Backups** — Velero or equivalent, target on TrueNAS share, applied across the platform.

Sub-projects #2 onwards are out of scope here and will get their own designs.

## Goals

- Establish a `gitops/` directory in this repository as the source of truth for K8s workloads.
- Use ApplicationSets (per-tier) so that adding a new app is "add a directory and merge."
- Make ArgoCD manage its own configuration (changes to ArgoCD go through PR/GitOps, not the deploy pipeline).
- Deploy MetalLB and local-path-provisioner so sub-project #2 can land cleanly.
- Add CI checks for `gitops/` so chart/values mistakes are caught at PR time.

## Non-Goals (explicitly out of scope)

- TLS Ingress, real DNS, cert-manager, Traefik, OpenBao, ESO — sub-project #2.
- Any media app values or namespaces — sub-project #3.
- Velero / backups — sub-project #5.
- external-dns, Renovate, image automation, SSO/OIDC, ArgoCD notifications — backlog.
- Migrating the existing Stage 4 Helm install entirely into GitOps — intentional retention; the bootstrap pattern requires it.

## Architecture

### Tiering

Three independent ApplicationSets, one per tier, each scoped to a directory under `gitops/apps/`:

| Tier | Directory | Sync policy | Rationale |
|---|---|---|---|
| `platform` | `gitops/apps/platform/` | `prune: false, selfHeal: true` | Critical infra (ArgoCD, MetalLB, future cert-manager etc.). selfHeal reverts manual `kubectl edit` drift. Prune disabled so an accidental directory deletion does not cascade-delete cert-manager CRDs. |
| `media` | `gitops/apps/media/` | `prune: true, selfHeal: true` | Stateless *arr apps. Removing a directory should remove the app cleanly. Auto-prune is appropriate. |
| `infra-tools` | `gitops/apps/infra-tools/` | `prune: false, selfHeal: true` | Reserved for backups (Velero), reloader, etc. — same caution as platform. Empty in #1. |

ApplicationSet templates use the `git.directories` generator scoped to their tier; per-app behavior is captured inside each app's wrapper chart.

### App format: wrapper Helm charts

Each app directory under `gitops/apps/platform/<name>/` is a self-contained Helm chart that depends on its upstream chart:

```
gitops/apps/platform/argocd/
├── Chart.yaml          # depends-on: argo-cd 9.5.0 from argoproj.github.io/argo-helm
├── values.yaml         # values passed to the upstream chart
└── templates/          # local resources (IngressRoute, ExternalSecret, etc. — empty for #1)
```

This pattern (mirrored from the reference repo `Chalupa-Tech/chalupa-infra`):

- Keeps each app fully self-described in one directory.
- Allows local resources (Traefik IngressRoute, ExternalSecret CRs, ConfigMaps) to ship alongside the upstream chart's templates.
- Lets ArgoCD render with a single `Application.spec.source.path` per app; no multi-source juggling, no per-app config.yaml.
- Requires `helm dependency update` to be run before push (handled by CI; documented in repo).

The `media` tier will follow a different pattern in #3 (every app is the bjw-s `app-template` chart with a unique values.yaml; ApplicationSet template hardcodes the chart). Out of scope here.

### Repository layout

```
gitops/
├── bootstrap/
│   ├── root-app.yaml                       # Application; spec.source.path = gitops/bootstrap/applicationsets
│   └── applicationsets/
│       ├── platform.yaml                   # git.directories → gitops/apps/platform/*
│       ├── media.yaml                      # git.directories → gitops/apps/media/*
│       └── infra-tools.yaml                # git.directories → gitops/apps/infra-tools/*
└── apps/
    ├── platform/
    │   ├── argocd/                         # wrapper of argo-cd 9.5.0
    │   │   ├── Chart.yaml
    │   │   ├── values.yaml
    │   │   └── templates/.gitkeep
    │   ├── metallb/                        # wrapper of metallb chart
    │   │   ├── Chart.yaml
    │   │   ├── values.yaml
    │   │   └── templates/
    │   │       ├── ipaddresspool.yaml      # 192.168.1.160-170
    │   │       └── l2advertisement.yaml
    │   └── local-path-provisioner/         # wrapper of local-path-provisioner chart
    │       ├── Chart.yaml
    │       ├── values.yaml
    │       └── templates/.gitkeep          # default StorageClass set via chart values
    ├── media/                              # populated in #3
    │   └── .gitkeep
    └── infra-tools/                        # populated as needed
        └── .gitkeep
```

### Bootstrap flow

`deploy.yml` Stage 4 evolves from "install ArgoCD" to "install ArgoCD, then hand it the keys":

1. **Helm install ArgoCD** — unchanged in spirit, but values move out of inline `--set` into a committed file `.github/argocd-bootstrap-values.yaml`. This file holds the absolute minimum needed to bring ArgoCD up. Nothing substantive — RBAC, repo creds, server config — lives here. Those go in `gitops/apps/platform/argocd/values.yaml`.
2. **Apply root Application** — `kubectl apply -n argocd -f gitops/bootstrap/root-app.yaml`. The root Application points at `gitops/bootstrap/applicationsets/`. ArgoCD reconciles, creates the three ApplicationSets, which fan out into Applications.
3. **ArgoCD reconciles itself** — the `argocd` Application (created by the platform ApplicationSet) renders `gitops/apps/platform/argocd/values.yaml` over the bootstrap install. From this point on, ArgoCD config changes go through PRs.

**Idempotency:** `helm upgrade --install` is a no-op when values match; `kubectl apply` is idempotent; ArgoCD reconciliation is idempotent. A clean cluster rebuild via the pipeline produces the same end state.

**Recovery from a broken self-managed values.yaml:** if `gitops/apps/platform/argocd/values.yaml` is bad enough to break ArgoCD, `kubectl rollout undo deployment/argocd-server -n argocd` reverts the deployment. Re-running the pipeline reapplies the bootstrap values. A comment to this effect lives at the top of the values file.

### ApplicationSet templates

**`gitops/bootstrap/applicationsets/platform.yaml`** (sketch):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-apps
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/Chalupa-Tech/chalupa-tech-local
        revision: main
        directories:
          - path: gitops/apps/platform/*
  template:
    metadata:
      name: '{{path.basename}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/Chalupa-Tech/chalupa-tech-local
        targetRevision: main
        path: '{{path}}'
        helm: {}                                 # Chart.yaml in the path drives the install
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'
      syncPolicy:
        automated:
          prune: false
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
```

`media.yaml` and `infra-tools.yaml` are structurally identical with their respective `metadata.name` (`media-apps`, `infra-tools-apps`), generator `path:`, and sync policy. Media's sync policy uses `prune: true`.

The ArgoCD repo URL is the `Chalupa-Tech/chalupa-tech-local` repo itself, which is public — no ArgoCD repo credentials needed.

### Per-app design

#### `gitops/apps/platform/argocd/`

- `Chart.yaml`: `apiVersion: v2`, `name: argocd-wrapper`, `dependencies: [{ name: argo-cd, version: 9.5.0, repository: https://argoproj.github.io/argo-helm }]`.
- `values.yaml`: nested under `argo-cd:` key. Contents for #1: minimal — server log level, basic resource requests, `configs.params."server.insecure": true` (TLS terminates at Traefik in #2; for now port-forward is fine). No Ingress in #1.
- A leading comment in `values.yaml` documents the recovery path if a bad change breaks ArgoCD.

#### `gitops/apps/platform/metallb/`

- `Chart.yaml`: depends on `metallb` (latest stable, pin to a 0.14.x version).
- `values.yaml`: defaults are mostly fine; enable speaker daemonset.
- `templates/ipaddresspool.yaml`: an `IPAddressPool` resource named `default-pool` covering `192.168.1.160-192.168.1.170`.
- `templates/l2advertisement.yaml`: an `L2Advertisement` referencing `default-pool`.
- **Ordering note:** MetalLB CRDs are installed by the chart; the `IPAddressPool` and `L2Advertisement` resources require those CRDs to exist first. ArgoCD handles this via `ServerSideApply=true` and retries; if first sync fails on missing CRDs, the second sync succeeds. Documented in implementation plan.

#### `gitops/apps/platform/local-path-provisioner/`

- `Chart.yaml`: depends on the Rancher local-path-provisioner Helm chart.
- `values.yaml`: configure path on each node (default `/opt/local-path-provisioner`); set the resulting StorageClass as the cluster default via `storageClass.defaultClass: true`.
- **Talos consideration:** Talos has read-only filesystems by default; the path used by local-path-provisioner must be on a writable mount. Talos's `ephemeral` partition is writable and persistent across reboots, so `/var/local-path-provisioner` (or `/opt/local-path-provisioner` if Talos allows it) is appropriate. Implementation plan must validate the path on the live cluster and choose accordingly. May require a Talos machine config patch via `pulumi-talos` to ensure the directory exists with correct permissions — flagged as a risk below.

### CI checks for `gitops/`

New workflow `.github/workflows/gitops.yml`, triggered on PR when `gitops/**` paths change:

1. **`yamllint`** on all YAML in `gitops/`.
2. **`helm dependency update`** then **`helm template`** for each chart in `gitops/apps/*/*/`. Catches invalid values, missing chart deps, syntax errors. Fails the PR if any chart fails to render.
3. **`kubeconform`** on the rendered output from step 2. Catches schema violations against the Kubernetes API.
4. **(Optional, deferred)** `argocd appset generate` for ApplicationSet dry-render. Skipped initially because the tooling is finicky; revisit if needed.

This is structurally similar to the existing `pulumi.yml` and `ansible.yml` workflows: lint + dry-run on PR, no apply.

### Interim ArgoCD UI access

Until sub-project #2 wires Ingress + TLS, ArgoCD UI is reached via:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# then browse https://localhost:8080
# initial admin password:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

No infra changes required. Replaced in #2 by an Ingress at `https://argocd.frame.chalupatech.com`.

## Verification

End-of-step verification checklist (run after the merge that delivers this work):

1. Pipeline runs green to the end of Stage 4.
2. `kubectl -n argocd get applicationset` shows three: `platform-apps`, `media-apps`, `infra-tools-apps`.
3. `kubectl -n argocd get application` shows `argocd`, `metallb`, `local-path-provisioner` — all `Synced` / `Healthy`.
4. `kubectl get sc` shows `local-path` marked `(default)`.
5. `kubectl -n metallb-system get ipaddresspool` shows `default-pool` covering `192.168.1.160-170`.
6. `kubectl -n metallb-system get l2advertisement` shows the advertisement is present.
7. ArgoCD UI loads via port-forward, login works.
8. **GitOps loop proof:** edit a benign field in `gitops/apps/platform/argocd/values.yaml` (e.g. server log level), open a PR, merge. ArgoCD picks up the change and reconciles without the pipeline rerunning the ArgoCD Helm install. The deployment's pod restarts with the new config.

## Risks and mitigations

- **Talos local-path-provisioner directory.** Talos's filesystem layout differs from generic Linux; the path the provisioner writes to must be on a writable mount. Mitigation: implementation plan includes a verification step that exec's into a node and confirms the path is writable; if not, add a Talos machine config patch in `pulumi-talos`.
- **MetalLB CRD-vs-CR ordering.** First sync may fail because `IPAddressPool` is applied before its CRD exists. Mitigation: `ServerSideApply=true` plus ArgoCD's automatic retry handles this; if not, add `argocd.argoproj.io/sync-wave` annotations to enforce ordering.
- **ArgoCD self-management deadlock.** A bad value pushed to `gitops/apps/platform/argocd/values.yaml` could break ArgoCD itself before it reconciles the next change. Mitigation: documented recovery via `kubectl rollout undo` and pipeline rerun; CI helm-template check catches most syntax errors at PR time.
- **Repo URL hardcoded in ApplicationSets.** If the repo is renamed/moved, the URLs in three places must change. Mitigation: ApplicationSets parameterize via a single value where possible; otherwise grep is fine.
- **Bootstrap values file diverges from GitOps values.** Two sources of truth for ArgoCD config is a smell. Mitigation: keep the bootstrap file deliberately minimal — server up, nothing more — and code-review it specifically for "is anything substantive in here that should be in `gitops/`?"

## Open questions

None blocking; small things to be resolved during implementation:

- Exact pinned chart versions for argo-cd, metallb, local-path-provisioner — chosen at implementation time from latest-stable.

## References

- Reference wrapper-chart pattern: `Chalupa-Tech/chalupa-infra` (`k8s/platform/openbao/Chart.yaml`).
- Existing Talos cluster setup: `docs/2026-04-13-add-talos-cluster.md`.
- Project conventions: `CLAUDE.md` (CI/CD pipeline, network table, critical rules).
