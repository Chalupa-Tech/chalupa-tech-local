# ArgoCD Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the GitOps foundation on the Talos cluster: a `gitops/` directory of wrapper-chart Applications, three tier-scoped ApplicationSets, ArgoCD self-management, plus MetalLB (LoadBalancer) and local-path-provisioner (default StorageClass) so subsequent sub-projects (Traefik, cert-manager, OpenBao, media stack) can land cleanly.

**Architecture:** Wrapper Helm chart per app under `gitops/apps/<tier>/<name>/` (Chart.yaml depending on upstream + values.yaml + templates/ for local resources). Three ApplicationSets (platform, media, infra-tools) using `git.directories` generators. `deploy.yml` Stage 4 evolves from "helm install ArgoCD" to "helm install ArgoCD with bootstrap values, then `kubectl apply` the root Application" — ArgoCD reconciles itself thereafter.

**Tech Stack:** Helm 3, ArgoCD v3.3 (chart 9.5.11), MetalLB 0.15.3, Rancher local-path-provisioner 0.0.36, kubeconform, yamllint, GitHub Actions, Talos Linux v1.12.

**Reference spec:** `docs/superpowers/specs/2026-05-03-argocd-foundation-design.md`

**Branching strategy:** Each task is one feature branch + one PR + one merge to `main`. Tasks 1-5 are inert in-cluster (they only add files; `deploy.yml` is unchanged). Task 6 is the activation point — its merge triggers the GitOps cascade. Task 7 verifies the loop.

---

## Pre-Flight: Local Tooling

Subagent must have these CLIs installed before starting any task:

- [ ] **Step P-1: Verify local tooling**

```bash
helm version --short                   # expect: v3.x
kubeconform -v                         # expect: v0.6+
yamllint --version                     # expect: any (pip install yamllint if missing)
gh --version                           # expect: gh version 2.x
```

If `kubeconform` is missing: `brew install kubeconform` (mac) or download from `https://github.com/yannh/kubeconform/releases`.
If `yamllint` is missing: `pip install yamllint`.

---

## Task 1: Repo Scaffold + CI Workflow

Creates the `gitops/` directory tree (empty placeholders) and the CI workflow that lints and dry-renders charts on PRs touching `gitops/`. The workflow runs on this PR itself and finds nothing to validate (no charts yet) — green CI is the proof the workflow is wired correctly.

**Files:**
- Create: `gitops/apps/platform/.gitkeep`
- Create: `gitops/apps/media/.gitkeep`
- Create: `gitops/apps/infra-tools/.gitkeep`
- Create: `gitops/bootstrap/.gitkeep`
- Create: `gitops/bootstrap/applicationsets/.gitkeep`
- Create: `.github/workflows/gitops.yml`

- [ ] **Step 1.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-scaffold
```

- [ ] **Step 1.2: Create the empty directory structure**

```bash
mkdir -p gitops/apps/platform gitops/apps/media gitops/apps/infra-tools \
         gitops/bootstrap/applicationsets
touch gitops/apps/platform/.gitkeep \
      gitops/apps/media/.gitkeep \
      gitops/apps/infra-tools/.gitkeep \
      gitops/bootstrap/.gitkeep \
      gitops/bootstrap/applicationsets/.gitkeep
```

- [ ] **Step 1.3: Create `.github/workflows/gitops.yml`**

```yaml
name: GitOps Lint & Render

on:
  pull_request:
    paths:
      - 'gitops/**'
      - '.github/workflows/gitops.yml'
  workflow_dispatch:

jobs:
  lint-and-render:
    name: Lint and dry-render gitops/
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Install yamllint
        run: pip install yamllint

      - name: Install Helm
        uses: azure/setup-helm@v4

      - name: Install kubeconform
        run: |
          curl -sSLo /tmp/kubeconform.tar.gz \
            https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz
          tar -xzf /tmp/kubeconform.tar.gz -C /tmp
          sudo mv /tmp/kubeconform /usr/local/bin/

      - name: yamllint gitops/
        run: yamllint -d '{extends: relaxed, rules: {line-length: disable}}' gitops/

      - name: Helm dependency update + template + kubeconform
        run: |
          set -euo pipefail
          shopt -s nullglob
          fail=0
          for chart_dir in gitops/apps/*/*/; do
            if [ -f "${chart_dir}Chart.yaml" ]; then
              echo "==> Rendering ${chart_dir}"
              helm dependency update "${chart_dir}"
              helm template "$(basename "${chart_dir}")" "${chart_dir}" \
                | kubeconform -strict -ignore-missing-schemas -summary \
                  -schema-location default \
                  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
                  || fail=1
            fi
          done
          if [ "$fail" -ne 0 ]; then exit 1; fi

      - name: yamllint applicationsets/
        run: |
          if compgen -G "gitops/bootstrap/applicationsets/*.yaml" > /dev/null; then
            yamllint -d '{extends: relaxed, rules: {line-length: disable}}' \
              gitops/bootstrap/applicationsets/
          else
            echo "No ApplicationSets yet — skipping"
          fi
```

- [ ] **Step 1.4: Locally verify workflow YAML is valid**

```bash
yamllint -d '{extends: relaxed, rules: {line-length: disable}}' .github/workflows/gitops.yml
```

Expected: no output (silent success).

- [ ] **Step 1.5: Locally verify yamllint passes on gitops/**

```bash
yamllint -d '{extends: relaxed, rules: {line-length: disable}}' gitops/
```

Expected: no output.

- [ ] **Step 1.6: Commit**

```bash
git add gitops/ .github/workflows/gitops.yml
git commit -m "$(cat <<'EOF'
feat(gitops): scaffold gitops/ directory and CI workflow

Adds empty tier directories (platform, media, infra-tools) plus
bootstrap/applicationsets/ scaffold. Adds gitops.yml workflow that
lints YAML, runs helm dependency update + helm template, and
validates rendered manifests with kubeconform. The workflow runs
on PRs touching gitops/** so subsequent task PRs are gated.
EOF
)"
```

- [ ] **Step 1.7: Push and open PR**

```bash
git push -u origin feat/gitops-scaffold
gh pr create --title "feat(gitops): scaffold gitops/ directory + CI workflow" \
  --body "$(cat <<'EOF'
## Summary

- Creates the `gitops/` directory tree (empty placeholders for the three tiers + bootstrap)
- Adds `.github/workflows/gitops.yml` to lint and dry-render charts on PRs

Part 1/7 of the ArgoCD foundation rollout. See `docs/superpowers/specs/2026-05-03-argocd-foundation-design.md` and `docs/superpowers/plans/2026-05-03-argocd-foundation-plan.md`.

This PR adds **no charts yet** and is in-cluster inert — it only establishes the directory structure and CI gate. Subsequent PRs add wrapper charts (which the workflow will validate) and finally activate the GitOps loop.

## Test plan

- [ ] CI workflow runs green
- [ ] No charts to render yet, but workflow completes successfully
- [ ] No changes to existing pipelines
EOF
)"
```

- [ ] **Step 1.8: Wait for CI to pass, then merge**

```bash
gh pr checks --watch
gh pr merge --squash --delete-branch
```

Expected: green checks, merge succeeds. After merge, `deploy.yml` runs; nothing changes in-cluster (no Pulumi/Ansible diffs, no GitOps cascade yet).

---

## Task 2: ArgoCD Wrapper Chart

Adds the ArgoCD wrapper chart that ArgoCD will eventually reconcile against itself. Inert until Task 6.

**Files:**
- Create: `gitops/apps/platform/argocd/Chart.yaml`
- Create: `gitops/apps/platform/argocd/values.yaml`
- Create: `gitops/apps/platform/argocd/templates/.gitkeep`
- Create: `gitops/apps/platform/argocd/.helmignore`

- [ ] **Step 2.1: Create branch from main**

```bash
git checkout main && git pull
git checkout -b feat/gitops-argocd-chart
```

- [ ] **Step 2.2: Create the chart directory and files**

```bash
mkdir -p gitops/apps/platform/argocd/templates
touch gitops/apps/platform/argocd/templates/.gitkeep
```

- [ ] **Step 2.3: Write `gitops/apps/platform/argocd/Chart.yaml`**

```yaml
apiVersion: v2
name: argocd-wrapper
description: Wrapper chart for ArgoCD self-management
type: application
version: 0.1.0
appVersion: "v3.3.9"
dependencies:
  - name: argo-cd
    version: 9.5.11
    repository: https://argoproj.github.io/argo-helm
```

- [ ] **Step 2.4: Write `gitops/apps/platform/argocd/values.yaml`**

```yaml
# ArgoCD self-managed values.
#
# RECOVERY: If a bad value here breaks ArgoCD itself, ArgoCD cannot reconcile
# the next change. Roll back the running deployment with:
#   kubectl rollout undo deployment/argocd-server -n argocd
#   kubectl rollout undo deployment/argocd-repo-server -n argocd
# Or rerun deploy.yml — Stage 4's helm upgrade reapplies the bootstrap
# values from .github/argocd-bootstrap-values.yaml and resets the cluster
# to the bootstrap baseline; ArgoCD will then attempt to reconcile this
# file again, so fix it first.

argo-cd:
  global:
    logging:
      level: info
  configs:
    params:
      # TLS terminates at Traefik in sub-project #2; until then UI is
      # accessed via kubectl port-forward and runs in insecure mode.
      server.insecure: true
  server:
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
  repoServer:
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
  controller:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
  applicationSet:
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
```

- [ ] **Step 2.5: Write `gitops/apps/platform/argocd/.helmignore`**

```
.gitkeep
.helmignore
```

- [ ] **Step 2.6: Locally fetch dependency and template the chart**

```bash
cd gitops/apps/platform/argocd
helm dependency update
helm template argocd . > /tmp/argocd-rendered.yaml
wc -l /tmp/argocd-rendered.yaml
cd -
```

Expected: `helm dependency update` succeeds, `Chart.lock` and `charts/argo-cd-9.5.11.tgz` appear; `helm template` writes ~5000+ lines to `/tmp/argocd-rendered.yaml`.

- [ ] **Step 2.7: Validate rendered manifests with kubeconform**

```bash
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/argocd-rendered.yaml
```

Expected: summary line says "Summary: X resources found ... Valid: X". No errors. CRDs may show as "skipped" — fine.

- [ ] **Step 2.8: Add chart lock + dependency to git, ignore vendored tgz**

Add to `.gitignore`:

```
gitops/apps/*/*/charts/
```

Then:

```bash
git add gitops/apps/platform/argocd/Chart.yaml \
        gitops/apps/platform/argocd/Chart.lock \
        gitops/apps/platform/argocd/values.yaml \
        gitops/apps/platform/argocd/templates/.gitkeep \
        gitops/apps/platform/argocd/.helmignore \
        .gitignore
```

- [ ] **Step 2.9: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(gitops): add ArgoCD wrapper chart for self-management

Wraps argo-cd 9.5.11 (app version v3.3.9). Values are minimal:
log level, modest resource requests, server.insecure=true (TLS
terminates at Traefik in sub-project #2). Inert until Task 6
wires deploy.yml to apply the root Application.

Top-level comment in values.yaml documents the recovery path
when a bad reconciliation breaks ArgoCD itself.
EOF
)"
```

- [ ] **Step 2.10: Push and open PR**

```bash
git push -u origin feat/gitops-argocd-chart
gh pr create --title "feat(gitops): add ArgoCD wrapper chart" \
  --body "$(cat <<'EOF'
## Summary

- Adds `gitops/apps/platform/argocd/` wrapping the upstream `argo-cd` Helm chart at version 9.5.11
- CI's `helm template` + `kubeconform` validate the chart renders cleanly

Part 2/7 of the ArgoCD foundation rollout. Inert in-cluster — `deploy.yml` is unchanged. Activated in Task 6.

## Test plan

- [ ] CI workflow renders the chart and validates manifests
- [ ] No changes to running cluster
EOF
)"
```

- [ ] **Step 2.11: Wait for CI, merge**

```bash
gh pr checks --watch
gh pr merge --squash --delete-branch
```

---

## Task 3: MetalLB Wrapper Chart

Adds MetalLB wrapper chart with IPAddressPool and L2Advertisement templates. Pool `192.168.1.160-170` per spec. Inert until Task 6.

**Files:**
- Create: `gitops/apps/platform/metallb/Chart.yaml`
- Create: `gitops/apps/platform/metallb/values.yaml`
- Create: `gitops/apps/platform/metallb/templates/ipaddresspool.yaml`
- Create: `gitops/apps/platform/metallb/templates/l2advertisement.yaml`
- Create: `gitops/apps/platform/metallb/.helmignore`

- [ ] **Step 3.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-metallb-chart
```

- [ ] **Step 3.2: Create directory**

```bash
mkdir -p gitops/apps/platform/metallb/templates
```

- [ ] **Step 3.3: Write `gitops/apps/platform/metallb/Chart.yaml`**

```yaml
apiVersion: v2
name: metallb-wrapper
description: Wrapper chart for MetalLB with default IPAddressPool
type: application
version: 0.1.0
appVersion: "v0.15.3"
dependencies:
  - name: metallb
    version: 0.15.3
    repository: https://metallb.github.io/metallb
```

- [ ] **Step 3.4: Write `gitops/apps/platform/metallb/values.yaml`**

```yaml
metallb:
  speaker:
    enabled: true
  controller:
    enabled: true
```

- [ ] **Step 3.5: Write `gitops/apps/platform/metallb/templates/ipaddresspool.yaml`**

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb
  annotations:
    # Apply after CRDs created by the dependency chart.
    argocd.argoproj.io/sync-wave: "1"
spec:
  addresses:
    - 192.168.1.160-192.168.1.170
  autoAssign: true
  avoidBuggyIPs: true
```

- [ ] **Step 3.6: Write `gitops/apps/platform/metallb/templates/l2advertisement.yaml`**

```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-l2
  namespace: metallb
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  ipAddressPools:
    - default-pool
```

- [ ] **Step 3.7: Write `gitops/apps/platform/metallb/.helmignore`**

```
.helmignore
```

- [ ] **Step 3.8: Render and validate locally**

```bash
cd gitops/apps/platform/metallb
helm dependency update
helm template metallb . > /tmp/metallb-rendered.yaml
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/metallb-rendered.yaml
cd -
```

Expected: clean render, kubeconform reports valid (IPAddressPool and L2Advertisement may be reported as "skipped, no schema" if CRD schemas don't fetch — that's expected).

- [ ] **Step 3.9: Commit and push**

```bash
git add gitops/apps/platform/metallb/
git commit -m "$(cat <<'EOF'
feat(gitops): add MetalLB wrapper chart with IPAddressPool

Wraps metallb 0.15.3. Configures one IPAddressPool (default-pool,
192.168.1.160-170) and one L2Advertisement. Sync-wave annotations
ensure CRs apply after the chart's CRDs install. Inert until Task 6.
EOF
)"
git push -u origin feat/gitops-metallb-chart
gh pr create --title "feat(gitops): add MetalLB wrapper chart" \
  --body "$(cat <<'EOF'
## Summary

- Adds `gitops/apps/platform/metallb/` wrapping `metallb` 0.15.3
- Reserves IP pool `192.168.1.160-192.168.1.170` for LoadBalancer services (reservation in Unifi DHCP also recommended; not in this PR)

Part 3/7 of the ArgoCD foundation rollout. Inert in-cluster.

## Test plan

- [ ] CI renders chart and validates manifests
- [ ] IPAddressPool / L2Advertisement YAML present in `gitops/apps/platform/metallb/templates/`
EOF
)"
gh pr checks --watch
gh pr merge --squash --delete-branch
```

---

## Task 4: local-path-provisioner Wrapper Chart

Adds local-path-provisioner wrapper. Sets the resulting StorageClass as cluster default. **Talos consideration:** Talos's `/var` is writable; default chart path `/opt/local-path-provisioner` is NOT. Override to `/var/local-path-provisioner` (directly under `/var`; note that `/var/mnt/` is reserved for mount points and is read-only).

**Files:**
- Create: `gitops/apps/platform/local-path-provisioner/Chart.yaml`
- Create: `gitops/apps/platform/local-path-provisioner/values.yaml`
- Create: `gitops/apps/platform/local-path-provisioner/templates/.gitkeep`
- Create: `gitops/apps/platform/local-path-provisioner/.helmignore`

- [ ] **Step 4.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-local-path-chart
```

- [ ] **Step 4.2: Create directory**

```bash
mkdir -p gitops/apps/platform/local-path-provisioner/templates
touch gitops/apps/platform/local-path-provisioner/templates/.gitkeep
```

- [ ] **Step 4.3: Write `gitops/apps/platform/local-path-provisioner/Chart.yaml`**

```yaml
apiVersion: v2
name: local-path-provisioner-wrapper
description: Wrapper chart for Rancher local-path-provisioner; default StorageClass
type: application
version: 0.1.0
appVersion: "v0.0.35"
dependencies:
  - name: local-path-provisioner
    version: 0.0.36
    repository: https://charts.containeroo.ch
```

- [ ] **Step 4.4: Write `gitops/apps/platform/local-path-provisioner/values.yaml`**

```yaml
# Talos exposes /var as writable+persistent. The chart's default
# /opt/local-path-provisioner path will fail on Talos because /opt
# is read-only.
local-path-provisioner:
  storageClass:
    create: true
    name: local-path
    defaultClass: true
    reclaimPolicy: Delete
  nodePathMap:
    - node: DEFAULT_PATH_FOR_NON_LISTED_NODES
      paths:
        - /var/local-path-provisioner
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
```

- [ ] **Step 4.5: Write `.helmignore`**

```
.gitkeep
.helmignore
```

- [ ] **Step 4.6: Render and validate**

```bash
cd gitops/apps/platform/local-path-provisioner
helm dependency update
helm template lpp . > /tmp/lpp-rendered.yaml
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  /tmp/lpp-rendered.yaml
grep -A2 'kind: StorageClass' /tmp/lpp-rendered.yaml
cd -
```

Expected: clean render, StorageClass `local-path` present with `storageclass.kubernetes.io/is-default-class: "true"` annotation.

- [ ] **Step 4.7: Commit, push, PR, merge**

```bash
git add gitops/apps/platform/local-path-provisioner/
git commit -m "$(cat <<'EOF'
feat(gitops): add local-path-provisioner wrapper as default StorageClass

Wraps Rancher local-path-provisioner 0.0.36. Overrides the default
hostPath to /var/local-path-provisioner because Talos's /opt is
read-only and /var/mnt/ is reserved for mount points. Marks the
resulting StorageClass as cluster default.
EOF
)"
git push -u origin feat/gitops-local-path-chart
gh pr create --title "feat(gitops): add local-path-provisioner wrapper" \
  --body "$(cat <<'EOF'
## Summary

- Adds `gitops/apps/platform/local-path-provisioner/` wrapping Rancher local-path-provisioner 0.0.36
- Marks resulting StorageClass `local-path` as cluster default
- Path overridden to `/var/local-path-provisioner` for Talos compatibility (Talos's `/opt` is read-only; `/var/mnt/` is reserved for mount points)

Part 4/7 of the ArgoCD foundation rollout. Inert in-cluster.

## Test plan

- [ ] CI renders chart and validates manifests
- [ ] StorageClass `local-path` present in rendered output with default annotation
EOF
)"
gh pr checks --watch
gh pr merge --squash --delete-branch
```

---

## Task 5: Bootstrap Manifests + ApplicationSets

Adds the root Application and three ApplicationSets. Still inert — `deploy.yml` doesn't apply these yet. Their existence in the repo is what Task 6 activates.

**Files:**
- Create: `gitops/bootstrap/root-app.yaml`
- Create: `gitops/bootstrap/applicationsets/platform.yaml`
- Create: `gitops/bootstrap/applicationsets/media.yaml`
- Create: `gitops/bootstrap/applicationsets/infra-tools.yaml`
- Delete: `gitops/bootstrap/.gitkeep`
- Delete: `gitops/bootstrap/applicationsets/.gitkeep`

- [ ] **Step 5.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-bootstrap-manifests
```

- [ ] **Step 5.2: Write `gitops/bootstrap/root-app.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/Chalupa-Tech/chalupa-tech-local
    targetRevision: main
    path: gitops/bootstrap/applicationsets
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 5.3: Write `gitops/bootstrap/applicationsets/platform.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions:
    - missingkey=error
  generators:
    - git:
        repoURL: https://github.com/Chalupa-Tech/chalupa-tech-local
        revision: main
        directories:
          - path: gitops/apps/platform/*
  template:
    metadata:
      name: '{{.path.basename}}'
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: https://github.com/Chalupa-Tech/chalupa-tech-local
        targetRevision: main
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated:
          prune: false
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
```

- [ ] **Step 5.4: Write `gitops/bootstrap/applicationsets/media.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: media-apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions:
    - missingkey=error
  generators:
    - git:
        repoURL: https://github.com/Chalupa-Tech/chalupa-tech-local
        revision: main
        directories:
          - path: gitops/apps/media/*
  template:
    metadata:
      name: '{{.path.basename}}'
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: https://github.com/Chalupa-Tech/chalupa-tech-local
        targetRevision: main
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: media
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
```

- [ ] **Step 5.5: Write `gitops/bootstrap/applicationsets/infra-tools.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: infra-tools-apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions:
    - missingkey=error
  generators:
    - git:
        repoURL: https://github.com/Chalupa-Tech/chalupa-tech-local
        revision: main
        directories:
          - path: gitops/apps/infra-tools/*
  template:
    metadata:
      name: '{{.path.basename}}'
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: https://github.com/Chalupa-Tech/chalupa-tech-local
        targetRevision: main
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated:
          prune: false
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
```

- [ ] **Step 5.6: Remove placeholder .gitkeep files now that real content exists**

```bash
git rm gitops/bootstrap/.gitkeep gitops/bootstrap/applicationsets/.gitkeep
```

- [ ] **Step 5.7: Locally validate ApplicationSet YAML**

```bash
yamllint -d '{extends: relaxed, rules: {line-length: disable}}' gitops/bootstrap/
```

Expected: no output.

- [ ] **Step 5.8: Validate root-app.yaml against ArgoCD CRD schema**

```bash
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  gitops/bootstrap/root-app.yaml \
  gitops/bootstrap/applicationsets/platform.yaml \
  gitops/bootstrap/applicationsets/media.yaml \
  gitops/bootstrap/applicationsets/infra-tools.yaml
```

Expected: kubeconform may say "skipped" for Application/ApplicationSet (CRDs from datreeio/CRDs-catalog cover argoproj.io); zero failures is the target.

- [ ] **Step 5.9: Commit, push, PR, merge**

```bash
git add gitops/bootstrap/
git commit -m "$(cat <<'EOF'
feat(gitops): add root Application and three ApplicationSets

Adds gitops/bootstrap/root-app.yaml plus three ApplicationSets
(platform, media, infra-tools) that fan out to gitops/apps/<tier>/*
via git.directories generators. Tier-specific sync policies:
- platform: prune=false, selfHeal=true (cautious)
- media: prune=true, selfHeal=true (stateless)
- infra-tools: prune=false, selfHeal=true (cautious)

Inert until Task 6 wires deploy.yml to apply root-app.yaml.
EOF
)"
git push -u origin feat/gitops-bootstrap-manifests
gh pr create --title "feat(gitops): add bootstrap manifests + ApplicationSets" \
  --body "$(cat <<'EOF'
## Summary

- Adds `gitops/bootstrap/root-app.yaml` (the App-of-Apps root)
- Adds three ApplicationSets: `platform-apps`, `media-apps`, `infra-tools-apps`
- Each uses a git.directories generator scoped to its tier
- Tier-specific sync policies per spec

Part 5/7 of the ArgoCD foundation rollout. Inert until next PR (deploy.yml wiring).

## Test plan

- [ ] CI yamllints all bootstrap files
- [ ] kubeconform validates Application + ApplicationSets
- [ ] No cluster changes
EOF
)"
gh pr checks --watch
gh pr merge --squash --delete-branch
```

---

## Task 6: Activate — Wire `deploy.yml` and Bootstrap Values

**This is the activation moment.** Refactors deploy.yml Stage 4 to use a committed bootstrap values file plus a kubectl-apply of the root Application. Merging this PR triggers ArgoCD to fan out and reconcile everything from Tasks 2-5.

**Files:**
- Create: `.github/argocd-bootstrap-values.yaml`
- Modify: `.github/workflows/deploy.yml` (Stage 4 only)

- [ ] **Step 6.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-activate
```

- [ ] **Step 6.2: Write `.github/argocd-bootstrap-values.yaml`**

```yaml
# Bootstrap-only values for ArgoCD installed by deploy.yml Stage 4.
#
# IMPORTANT: Keep this file MINIMAL. Anything substantive (RBAC, repo creds,
# server config) goes in gitops/apps/platform/argocd/values.yaml, which ArgoCD
# reconciles itself once the root Application is applied.
#
# This file exists only so a clean cluster rebuild can boot ArgoCD before
# anything else. After bootstrap, ArgoCD's own Application overlays the real
# values.

global:
  logging:
    level: info
configs:
  params:
    # TLS terminates at Traefik in sub-project #2; until then the UI is
    # accessed via kubectl port-forward and ArgoCD runs in insecure mode.
    server.insecure: true
```

- [ ] **Step 6.3: Read current Stage 4 of deploy.yml**

```bash
grep -n "Stage 4" .github/workflows/deploy.yml
sed -n '/Stage 4/,/^  [a-z]/p' .github/workflows/deploy.yml | head -80
```

Note the line range that holds the `helm upgrade --install argocd ...` step.

- [ ] **Step 6.4: Update Stage 4 — replace the inline `--set` Helm install with values file + kubectl apply**

Find the existing step:

```yaml
      - name: Install ArgoCD
        run: |
          export KUBECONFIG=/tmp/kubeconfig
          helm repo add argo https://argoproj.github.io/argo-helm
          helm repo update
          helm upgrade --install argocd argo/argo-cd \
            --namespace argocd --create-namespace \
            --version 9.5.0 \
            --wait --timeout 5m
```

Replace it with two steps:

```yaml
      - name: Install ArgoCD (bootstrap)
        run: |
          export KUBECONFIG=/tmp/kubeconfig
          helm repo add argo https://argoproj.github.io/argo-helm
          helm repo update
          helm upgrade --install argocd argo/argo-cd \
            --namespace argocd --create-namespace \
            --version 9.5.11 \
            --values .github/argocd-bootstrap-values.yaml \
            --wait --timeout 5m

      - name: Apply root Application
        run: |
          export KUBECONFIG=/tmp/kubeconfig
          kubectl apply -n argocd -f gitops/bootstrap/root-app.yaml
          # Wait for the root app to be created; ApplicationSets will fan
          # out asynchronously and reconcile in the background. We don't
          # block the pipeline on Synced/Healthy here because first sync
          # of MetalLB CRDs may need a retry pass.
          kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=60s || true
          kubectl get -n argocd application root || true
```

- [ ] **Step 6.5: Lint the modified deploy.yml**

```bash
yamllint -d '{extends: relaxed, rules: {line-length: disable}}' .github/workflows/deploy.yml
```

Expected: no output.

- [ ] **Step 6.6: Pre-merge sanity — re-render gitops charts to confirm nothing broke**

```bash
for chart_dir in gitops/apps/*/*/; do
  if [ -f "${chart_dir}Chart.yaml" ]; then
    echo "==> ${chart_dir}"
    helm dependency update "${chart_dir}"
    helm template "$(basename "${chart_dir}")" "${chart_dir}" > /dev/null
  fi
done
echo "All charts render cleanly."
```

- [ ] **Step 6.7: Commit, push, PR**

```bash
git add .github/argocd-bootstrap-values.yaml .github/workflows/deploy.yml
git commit -m "$(cat <<'EOF'
feat(gitops): activate ArgoCD self-management via root Application

Stage 4 of deploy.yml now installs ArgoCD with a minimal bootstrap
values file (.github/argocd-bootstrap-values.yaml), then kubectl
applies gitops/bootstrap/root-app.yaml. The root Application points
at gitops/bootstrap/applicationsets/, which fans out to platform,
media, and infra-tools ApplicationSets. Platform ApplicationSet
picks up gitops/apps/platform/argocd/values.yaml and reconciles
ArgoCD's own configuration on top of the bootstrap baseline.

Bootstrap values are deliberately minimal: log level + server.insecure.
All substantive configuration lives in the GitOps values file.

Bumps the chart version from 9.5.0 to 9.5.11 (latest patch).
EOF
)"
git push -u origin feat/gitops-activate
gh pr create --title "feat(gitops): activate ArgoCD self-management" \
  --body "$(cat <<'EOF'
## Summary

- Adds `.github/argocd-bootstrap-values.yaml` (minimal values for first-boot ArgoCD)
- Updates `deploy.yml` Stage 4 to use the values file + apply `gitops/bootstrap/root-app.yaml`
- Bumps argo-cd chart from 9.5.0 → 9.5.11 (patch)

**This is the activation PR.** Merging triggers ArgoCD to reconcile all wrapper charts merged in Tasks 2-4 (argocd, metallb, local-path-provisioner). After merge, follow the verification runbook in the implementation plan.

## Test plan

- [ ] CI passes (yamllint, no helm chart changes triggered by this PR)
- [ ] Post-merge: pipeline runs green to end of Stage 4
- [ ] Post-merge: `kubectl -n argocd get applicationset` shows three
- [ ] Post-merge: `kubectl -n argocd get application` shows `argocd`, `metallb`, `local-path-provisioner` all Synced/Healthy
- [ ] Post-merge: `kubectl get sc` shows `local-path` marked default
- [ ] Post-merge: `kubectl -n metallb get ipaddresspool` shows `default-pool` (192.168.1.160-170)
EOF
)"
gh pr checks --watch
```

- [ ] **Step 6.8: Merge and observe deploy**

```bash
gh pr merge --squash --delete-branch
# Watch deploy.yml run
gh run watch
```

Expected: deploy.yml runs Stages 1-4 green. Stage 4 logs show:
1. `Install ArgoCD (bootstrap)` — helm upgrade succeeds, "STATUS: deployed"
2. `Apply root Application` — `application.argoproj.io/root created` (or `unchanged` on rerun)

- [ ] **Step 6.9: Pull kubeconfig and verify cluster state**

```bash
cd pulumi-talos
pulumi stack output kubeconfig --show-secrets > /tmp/kubeconfig
export KUBECONFIG=/tmp/kubeconfig
cd -

kubectl -n argocd get application
kubectl -n argocd get applicationset
kubectl get sc
kubectl get ns metallb 2>&1 || echo "metallb namespace not yet created"
```

Expected progression (may take 1-3 minutes for full reconciliation after pipeline finishes):

1. `applicationset` shows `platform-apps`, `media-apps`, `infra-tools-apps`.
2. `application` shows `root`, then `argocd`, `metallb`, `local-path-provisioner` appearing one-by-one as the platform ApplicationSet reconciles.
3. Each application progresses `OutOfSync` → `Syncing` → `Synced` and `Missing` → `Progressing` → `Healthy`.
4. `sc` shows `local-path (default)`.
5. `metallb` namespace appears with controller and speaker pods Running.

- [ ] **Step 6.10: Verify MetalLB IPAddressPool was applied**

```bash
kubectl -n metallb get ipaddresspool default-pool -o yaml | grep -A2 'addresses:'
kubectl -n metallb get l2advertisement default-l2 -o yaml | grep -A3 'spec:'
```

Expected: address pool shows `192.168.1.160-192.168.1.170`; l2advertisement references `default-pool`.

- [ ] **Step 6.11: Recovery instructions if any application is stuck**

If `metallb` stays `OutOfSync` because IPAddressPool applies before its CRD is ready, give it 60 seconds to retry on its own. If still stuck:

```bash
kubectl -n argocd patch application metallb --type merge -p '{"operation":{"sync":{}}}'
```

If `local-path-provisioner` pods are CrashLoopBackoff because of write permission on `/var/local-path-provisioner`, exec into a Talos node:

```bash
talosctl -n 192.168.1.225 mount | grep -E "/var(\s|$)"
```

If `/var` is mounted read-only, fall back to `/var/openebs/local` (or another writable Talos path) by editing `gitops/apps/platform/local-path-provisioner/values.yaml` in a hotfix PR.

- [ ] **Step 6.12: Open ArgoCD UI to confirm**

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
sleep 2
PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
echo "ArgoCD UI: https://localhost:8080"
echo "Username: admin"
echo "Password: $PASSWORD"
```

Expected: UI loads (browser warning on self-signed cert is normal pre-#2). Login succeeds. Application tree shows root → 3 ApplicationSets → 3 Applications all Synced/Healthy.

```bash
# Kill the port-forward when done.
kill %1
```

---

## Task 7: GitOps Loop Verification

Final task. Makes a benign change to ArgoCD's own values via PR; observes ArgoCD reconcile itself without the pipeline rerunning Helm. This proves the loop is closed.

**Files:**
- Modify: `gitops/apps/platform/argocd/values.yaml` (one field)

- [ ] **Step 7.1: Create branch**

```bash
git checkout main && git pull
git checkout -b chore/gitops-loop-proof
```

- [ ] **Step 7.2: Change the log level from `info` to `debug`**

In `gitops/apps/platform/argocd/values.yaml`:

```yaml
argo-cd:
  global:
    logging:
      level: debug    # was: info
```

- [ ] **Step 7.3: Render locally to confirm**

```bash
cd gitops/apps/platform/argocd
helm template argocd . | grep -A1 ARGOCD_LOG_LEVEL || echo "no env literal — chart wires via configmap"
cd -
```

(The exact rendering varies; the goal is just to confirm the chart still templates cleanly.)

- [ ] **Step 7.4: Commit, push, PR, merge**

```bash
git add gitops/apps/platform/argocd/values.yaml
git commit -m "$(cat <<'EOF'
chore(gitops): bump ArgoCD log level to debug to verify loop

Benign change to prove ArgoCD reconciles its own values from Git
without the deploy pipeline running. Will be reverted in a follow-up
once verified.
EOF
)"
git push -u origin chore/gitops-loop-proof
gh pr create --title "chore(gitops): verify GitOps loop with log-level bump" \
  --body "$(cat <<'EOF'
## Summary

Bumps ArgoCD's log level from `info` → `debug` as a one-field change to verify the GitOps loop closes correctly.

## Test plan

- [ ] CI renders the chart cleanly
- [ ] Merging this PR does NOT cause `deploy.yml` to rerun Stage 4's Helm install (no Pulumi/Ansible changes)
- [ ] Within ~3 minutes of merge, ArgoCD's repo-server polls main, picks up the change
- [ ] `kubectl -n argocd get application argocd` shows `OutOfSync` briefly, then `Synced`
- [ ] `kubectl -n argocd describe configmap argocd-cmd-params-cm` shows the new log level (or check argocd-server pod logs for log-level on startup)
- [ ] `kubectl -n argocd logs -l app.kubernetes.io/name=argocd-server --tail=20` shows debug-level lines
EOF
)"
gh pr checks --watch
gh pr merge --squash --delete-branch
```

- [ ] **Step 7.5: Watch ArgoCD reconcile**

```bash
export KUBECONFIG=/tmp/kubeconfig
# Force a refresh so we don't wait the full poll interval
kubectl -n argocd patch application argocd --type merge -p '{"operation":{"sync":{}}}'

# Watch
watch -n 2 'kubectl -n argocd get application argocd'
```

Expected: status goes `Synced/Healthy` → `OutOfSync/Healthy` → `Syncing` → `Synced/Healthy` within ~30s of the manual refresh (or up to 3 minutes if waiting for the default poll interval).

- [ ] **Step 7.6: Confirm the new log level took effect**

```bash
kubectl -n argocd rollout status deployment/argocd-server --timeout=60s
kubectl -n argocd logs -l app.kubernetes.io/name=argocd-server --tail=30 | grep -i 'level=debug' | head -5
```

Expected: at least one log line with `level=debug`. **The GitOps loop is proven.**

- [ ] **Step 7.7: Revert log level (optional cleanup PR)**

```bash
git checkout main && git pull
git checkout -b chore/gitops-revert-log-level
```

Edit `gitops/apps/platform/argocd/values.yaml` back to `level: info`. Commit, push, open & merge PR.

---

## Final Verification (matches spec acceptance criteria)

After Task 7 merges (and the optional cleanup):

- [ ] **F-1:** `kubectl -n argocd get applicationset` shows three: `platform-apps`, `media-apps`, `infra-tools-apps`.
- [ ] **F-2:** `kubectl -n argocd get application` shows `root`, `argocd`, `metallb`, `local-path-provisioner` — all Synced/Healthy.
- [ ] **F-3:** `kubectl get sc` shows `local-path` marked `(default)`.
- [ ] **F-4:** `kubectl -n metallb get ipaddresspool` shows `default-pool` covering `192.168.1.160-170`.
- [ ] **F-5:** `kubectl -n metallb get l2advertisement` shows `default-l2`.
- [ ] **F-6:** ArgoCD UI loads via `kubectl port-forward`, login works.
- [ ] **F-7:** Task 7 demonstrated successful end-to-end reconciliation from a Git change with no pipeline rerun.

Sub-project #1 complete. Move on to sub-project #2 (Secrets + TLS Ingress) when ready.

---

## Risk Recap (from spec)

- **Talos `/var/local-path-provisioner`** may not be writable on first try. Fallback paths: `/var/openebs/local`, `/var/lib/local-path-provisioner`. Hotfix in a follow-up PR if needed. (Note: an earlier iteration used `/var/mnt/local-path-provisioner`, which fails because `/var/mnt/` is reserved for mount points and is read-only on Talos.)
- **MetalLB CRD-vs-CR ordering** handled via `argocd.argoproj.io/sync-wave: "1"` annotations on IPAddressPool/L2Advertisement.
- **ArgoCD self-management deadlock** — recovery via `kubectl rollout undo deployment/argocd-server -n argocd` and rerunning the pipeline. Documented in `gitops/apps/platform/argocd/values.yaml` header comment.
- **Bootstrap-vs-GitOps values divergence** — bootstrap values are deliberately minimal (log level + insecure flag). PR review specifically watches for substantive config leaking into the bootstrap file.
