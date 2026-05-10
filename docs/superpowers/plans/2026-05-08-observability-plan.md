# Observability (Metrics & Visualization) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land an end-to-end metrics + visualization stack on the Talos cluster: `kubectl top` works, VictoriaMetrics stores 30 days of timeseries, Grafana renders 8 starter dashboards over HTTPS at `grafana.frame.chalupatech.com`, and the foundational layer (kubelet, cAdvisor, kube-state-metrics, node-exporter) plus existing platform apps (ArgoCD, Traefik, ESO, OpenBao, CNPG, arrs-pg) are all scraped from day 1.

**Architecture:** New `observability` ApplicationSet tier under `gitops/apps/observability/` (clone of `platform.yaml`). vm-operator deploys `VMSingle` (single-node TSDB, 30d retention, 40 Gi local-path) + `VMAgent` (single replica, 5 Gi WAL on local-path) per the spec. Prometheus-operator CRDs (CRDs only, no controller) install in their own app so chart toggles like `serviceMonitor.enabled: true` work cluster-wide. Grafana sidecar auto-loads ConfigMap-backed datasources and dashboards; raw dashboard JSON files committed at the chart root and rendered via `.Files.Get`. Admin password sourced from OpenBao via ESO. `metrics-server` lands separately in the `platform` tier (it serves `metrics.k8s.io` for HPA/`kubectl top`, not Prometheus). Eight PRs land sequentially, each gated on the deploy.yml `Verify GitOps reconciliation` step, mirroring sub-projects #1–#4.

**Tech Stack:** Helm 3, kubeconform, ArgoCD ApplicationSet, External Secrets Operator 2.4.x, OpenBao 0.27.x, VictoriaMetrics Operator 0.49.x (chart) / 0.49+ (operator app version), VictoriaMetrics 1.108.x (TSDB + agent), prometheus-operator-crds 18.x (CRDs only), kube-state-metrics 5.27.x, prometheus-node-exporter 4.40.x, Grafana 11.x (chart 8.x), metrics-server 3.12.x. Pinned chart versions in this plan are the targeted starting point as of 2026-05-08; bump within the same minor at impl time if newer is stable on `helm search repo --versions`.

**Reference spec:** `docs/superpowers/specs/2026-05-08-observability-design.md`.

**Branching strategy:** One feature branch per task, one PR per task, one merge to `main`. Tasks 1, 2, 3, 4, 5, 6, 8, 9 are PR-driven. Task 7 is a **manual operator runbook** that does not produce a PR.

**Pre-existing prerequisites (already satisfied):**

- All 9 platform Applications Synced/Healthy: `argocd`, `metallb`, `local-path-provisioner`, `openbao`, `external-secrets`, `cert-manager`, `traefik`, `external-dns`, `cnpg-system`.
- All 6 media Applications Synced/Healthy: `nzbget`, `sonarr`, `radarr`, `seerr`, `tdarr`, `arrs-pg`.
- ESO `ClusterSecretStore openbao` is `Ready: True`.
- OpenBao `external-secrets` Vault role is bound to SA `external-secrets/external-secrets` with policies `cloudflare-read` + `media-read`.
- 6 Talos nodes Ready: 3 CPs (.225, .228, .229) at 2c/6GB/50GB, 3 workers (.226, .227, .232) at 4c/20GB/100GB. PR #148 grew worker disks 50 → 100 GB on 2026-05-08, merged.
- `gitops/apps/platform/local-path-provisioner/values.yaml` exists; `local-path` is the cluster default StorageClass.
- TrueNAS NFS share at `/mnt/PlexMedia/frame` mounted by media apps. (Not used by observability.)
- The default Traefik TLSStore wildcard cert covers `*.frame.chalupatech.com` (deployed in #2).
- Unifi DNS override resolves `*.frame.chalupatech.com → 192.168.1.230` on LAN.
- `~/secure/openbao-init.json` exists on the operator's machine (also stored in 1Password) — needed for Task 7.

---

## Pre-Flight: Local Tooling

Subagent must have these CLIs installed and KUBECONFIG/TALOSCONFIG configured before starting any task.

- [ ] **Step P-1: Verify local CLIs**

```bash
helm version --short                    # expect: v3.x
kubeconform -v                          # expect: v0.6+
yamllint --version                      # expect: any
gh --version                            # expect: gh version 2.x
jq --version                            # expect: jq-1.6+
kubectl version --client                # expect: v1.30+ (Homebrew-signed)
talosctl version --client               # expect: v1.12+
curl --version | head -1                # expect: any
```

If any are missing: `brew install <tool>`. kubectl must be the Homebrew-signed binary, not an adhoc-signed manual install (per `project_tailscale_kubectl_ehostunreach` memory).

- [ ] **Step P-2: Set KUBECONFIG**

```bash
cd pulumi-talos && pulumi stack output kubeconfig --show-secrets > ~/.kube/chalupa-cluster.yaml && cd -
chmod 600 ~/.kube/chalupa-cluster.yaml
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
kubectl get nodes
```

Expected: 6 nodes Ready (3 CPs + 3 workers). If `no route to host`, switch to `sudo kubectl ...` for everything (Tailscale macOS Network Extension interception per `project_tailscale_kubectl_ehostunreach` memory).

- [ ] **Step P-3: Sanity-check existing prerequisites**

```bash
kubectl -n external-secrets get clustersecretstore openbao
# Expect: STATUS=Valid, READY=True

kubectl get sc local-path
# Expect: local-path is the default class (annotated with storageclass.kubernetes.io/is-default-class: "true")

kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.ephemeral-storage}{"\n"}{end}'
# Expect: 6 lines. Workers (.226, .227, .232) show ~94Gi-ish ephemeral-storage (after PR #148 disk grow); CPs show ~46Gi-ish.

kubectl -n media get cluster arrs-pg
# Expect: STATUS=Cluster in healthy state, READY=3
```

If any check fails, do not start the plan — fix the precondition first.

- [ ] **Step P-4: Pull the prometheus-community + grafana + cnpg + victoriametrics + metrics-server helm repos**

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update

# Confirm the charts we'll consume are visible:
helm search repo prometheus-community/prometheus-operator-crds | head -3
helm search repo prometheus-community/kube-state-metrics | head -3
helm search repo prometheus-community/prometheus-node-exporter | head -3
helm search repo grafana/grafana | head -3
helm search repo metrics-server/metrics-server | head -3
helm search repo vm/victoria-metrics-operator | head -3
```

Each should print at least one row.

---

## Task 1: PR 1 — `local-path-provisioner` `allowVolumeExpansion: true`

Adds `allowVolumeExpansion: true` to the existing `local-path` StorageClass so observability PVCs (and any future PVC) can be grown via `kubectl edit pvc` without pod restart. local-path doesn't enforce quotas at the filesystem level, so the resize is metadata-only — but the K8s API still requires this flag to accept resize requests.

**Files:**
- Modify: `gitops/apps/platform/local-path-provisioner/values.yaml`

- [ ] **Step 1.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/local-path-allow-volume-expansion
```

- [ ] **Step 1.2: Read current values.yaml**

```bash
cat gitops/apps/platform/local-path-provisioner/values.yaml
```

Expected current contents (anchor):

```yaml
# Talos exposes /var as writable+persistent (the ephemeral partition).
# /var/mnt/ is reserved for mount points and is read-only; using
# /var/local-path-provisioner directly avoids that constraint.
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

- [ ] **Step 1.3: Add `allowVolumeExpansion: true` under `storageClass`**

Use Edit to change:

```yaml
  storageClass:
    create: true
    name: local-path
    defaultClass: true
    reclaimPolicy: Delete
```

to:

```yaml
  storageClass:
    create: true
    name: local-path
    defaultClass: true
    reclaimPolicy: Delete
    allowVolumeExpansion: true
```

- [ ] **Step 1.4: Render + validate**

```bash
helm dependency update gitops/apps/platform/local-path-provisioner/ 2>/dev/null || true
helm template local-path-provisioner gitops/apps/platform/local-path-provisioner/ > /tmp/lpp-render.yaml

# Confirm the StorageClass picked up the flag:
grep -A1 'kind: StorageClass' /tmp/lpp-render.yaml
grep 'allowVolumeExpansion' /tmp/lpp-render.yaml
# Expect: one line: allowVolumeExpansion: true
```

If `grep allowVolumeExpansion` returns no match, the chart's value path may differ in this version — inspect `helm show values local-path-provisioner/local-path-provisioner` to find the right key, then update values.yaml accordingly.

- [ ] **Step 1.5: yamllint + kubeconform**

```bash
yamllint gitops/apps/platform/local-path-provisioner/

kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  /tmp/lpp-render.yaml
# Expect: 0 invalid resources.
```

- [ ] **Step 1.6: Commit, push, open PR**

```bash
git add gitops/apps/platform/local-path-provisioner/values.yaml
git commit -m "$(cat <<'EOF'
feat(local-path): allow volume expansion

Enables the storageClass.allowVolumeExpansion flag on the
local-path StorageClass so PVCs can be grown via kubectl edit
pvc without pod restart. local-path doesn't enforce quotas at
the filesystem layer, so the resize is metadata-only — but the
K8s API still requires this flag to accept resize requests.

Precursor to sub-project #5 (observability) — vmsingle/vmagent/
grafana PVCs need to be sizeable later as data accumulates or
retention bumps. PR #148 already grew worker disks 50 → 100 GB
to make the headroom physically real.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin feat/local-path-allow-volume-expansion

gh pr create --title "feat(local-path): allow volume expansion" --body "$(cat <<'EOF'
## Summary
- Adds \`allowVolumeExpansion: true\` to the local-path StorageClass
- One-line values.yaml change; no chart bump
- Enables online PVC resize for future observability/CNPG growth

## Why
Sub-project #5 (observability) brainstorming surfaced that PVC resize was blocked because allowVolumeExpansion wasn't set. Landing this first so #5's vmsingle/vmagent/grafana PVCs can be grown later without pod restart.

## Test plan
- [ ] CI helm template renders cleanly
- [ ] After merge: \`kubectl get sc local-path -o jsonpath='{.allowVolumeExpansion}'\` returns \`true\`
- [ ] Existing PVCs unaffected (sanity: \`kubectl get pvc -A\` is unchanged)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 1.7: STOP — wait for user to merge PR**

Surface the PR URL. Wait for user confirmation that the PR has been merged before proceeding.

- [ ] **Step 1.8: Post-merge verification**

```bash
git checkout main && git pull

kubectl get sc local-path -o jsonpath='{.allowVolumeExpansion}'
# Expect: true

kubectl -n argocd get app local-path-provisioner
# Expect: Synced/Healthy

# Existing PVCs unaffected:
kubectl get pvc -A | wc -l
# Expect: same count as before merge
```

---

## Task 2: PR 2 — `platform/metrics-server`

Adds `metrics-server` to the platform tier. Serves `metrics.k8s.io` API for `kubectl top`, HPA, future autoscalers. Distinct from the Prometheus/VM stack — it's a Kubernetes API extension, not a scrape target consumer.

**Files:**
- Create: `gitops/apps/platform/metrics-server/Chart.yaml`
- Create: `gitops/apps/platform/metrics-server/values.yaml`
- Create: `gitops/apps/platform/metrics-server/.helmignore`
- Create: `gitops/apps/platform/metrics-server/templates/namespace.yaml`

- [ ] **Step 2.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-metrics-server
```

- [ ] **Step 2.2: Create directory structure**

```bash
mkdir -p gitops/apps/platform/metrics-server/templates
```

- [ ] **Step 2.3: Write `gitops/apps/platform/metrics-server/Chart.yaml`**

```yaml
apiVersion: v2
name: metrics-server-wrapper
description: Wrapper chart for metrics-server (serves metrics.k8s.io API for kubectl top + HPA)
type: application
version: 0.1.0
appVersion: "0.7.2"
dependencies:
  - name: metrics-server
    version: 3.12.2
    repository: https://kubernetes-sigs.github.io/metrics-server/
```

If a newer 3.12.x is current at impl time, bump within the same minor.

- [ ] **Step 2.4: Write `gitops/apps/platform/metrics-server/.helmignore`**

```
.git/
.gitignore
.DS_Store
*.swp
*.swo
*~
```

(Do NOT include `charts/` — that's the vendored dep dir per the lessons-from-#3 memory. Excluding it would prevent helm from finding the metrics-server chart.)

- [ ] **Step 2.5: Write `gitops/apps/platform/metrics-server/values.yaml`**

```yaml
metrics-server:
  replicas: 1

  args:
    # Talos's kubelet uses self-signed serving certs by default; metrics-server
    # talks to kubelet's /metrics/resource. Skip TLS verification on that path.
    - --kubelet-insecure-tls
    # Prefer InternalIP for kubelet addressing (Talos sets node IPs as InternalIP).
    - --kubelet-preferred-address-types=InternalIP

  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 50m
      memory: 128Mi  # Guaranteed QoS — small, foundational

  apiService:
    create: true
```

- [ ] **Step 2.6: Write `gitops/apps/platform/metrics-server/templates/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: metrics-server
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

- [ ] **Step 2.7: Helm dependency update**

```bash
helm dependency update gitops/apps/platform/metrics-server/
ls gitops/apps/platform/metrics-server/charts/
# Expect: metrics-server-3.12.x.tgz

test -f gitops/apps/platform/metrics-server/Chart.lock && echo "Chart.lock generated"
```

- [ ] **Step 2.8: Render + validate**

```bash
helm template metrics-server gitops/apps/platform/metrics-server/ > /tmp/ms-render.yaml
wc -l /tmp/ms-render.yaml
# Expect: ~200-400 lines (small chart)

kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  /tmp/ms-render.yaml
# Expect: 0 invalid resources.

yamllint gitops/apps/platform/metrics-server/
```

- [ ] **Step 2.9: Commit, push, open PR**

```bash
git add gitops/apps/platform/metrics-server/
git commit -m "$(cat <<'EOF'
feat(metrics-server): platform-tier wrapper chart

Adds metrics-server as a platform-tier Application via the
existing platform-apps ApplicationSet. Serves metrics.k8s.io
API for kubectl top, HPA, and future autoscalers. Distinct
from the Prometheus/VM stack — it's a K8s API extension, not
a scrape consumer.

Talos-specific tuning: --kubelet-insecure-tls (Talos kubelets
use self-signed serving certs) + --kubelet-preferred-address
-types=InternalIP. Single replica, Guaranteed QoS at 50m/128Mi.

PR 2 of 8 in sub-project #5 (observability).
Spec: docs/superpowers/specs/2026-05-08-observability-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin feat/gitops-metrics-server

gh pr create --title "feat(metrics-server): platform-tier wrapper chart" --body "$(cat <<'EOF'
## Summary
- New platform-tier app: \`gitops/apps/platform/metrics-server/\`
- metrics-server 3.12.x serving \`metrics.k8s.io\` API
- Talos-tuned (--kubelet-insecure-tls + InternalIP preference)
- Single replica, Guaranteed QoS

## Test plan
- [ ] CI helm template renders cleanly
- [ ] After merge: \`kubectl -n argocd get app metrics-server\` Synced/Healthy
- [ ] After merge: \`kubectl top nodes\` returns 6 rows with real values
- [ ] After merge: \`kubectl top pods -n media\` returns real values

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2.10: STOP — wait for user to merge**

- [ ] **Step 2.11: Post-merge verification**

```bash
git checkout main && git pull

kubectl -n argocd get app metrics-server
# Expect: Synced/Healthy

kubectl -n metrics-server get pods
# Expect: metrics-server-* 1/1 Running

# Wait ~30s for the Metrics API to populate, then:
kubectl top nodes
# Expect: 6 rows with CPU + memory values, no "metrics not available" error.

kubectl top pods -n media
# Expect: ~6+ rows (sonarr/radarr/seerr/nzbget/tdarr + arrs-pg pods).
```

---

## Task 3: PR 3 — `observability` ApplicationSet (empty tier)

Creates the new observability tier's ApplicationSet. The directory glob `gitops/apps/observability/*` matches nothing yet, so the ApplicationSet generates 0 child Applications — but the appset itself is created so subsequent PRs (4–7) only have to drop wrapper charts into the directory and ArgoCD picks them up automatically.

**Files:**
- Create: `gitops/bootstrap/applicationsets/observability.yaml`

- [ ] **Step 3.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-observability-appset
```

- [ ] **Step 3.2: Inspect platform.yaml as template**

```bash
cat gitops/bootstrap/applicationsets/platform.yaml
```

The new file is a near-clone with just the ApplicationSet metadata.name and the directory glob changed.

- [ ] **Step 3.3: Write `gitops/bootstrap/applicationsets/observability.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: observability-apps
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
          - path: gitops/apps/observability/*
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
        retry:
          limit: 5
          backoff:
            duration: 30s
            factor: 2
            maxDuration: 5m
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
          - SkipDryRunOnMissingResource=true
      # Same admission-controller drift block as platform.yaml — silences
      # false-positive drift on ESO-defaulted ExternalSecret fields. Future
      # observability apps using ESO will inherit this; it's a no-op until
      # an ExternalSecret is added (Grafana wrapper in Task 8).
      ignoreDifferences:
        - group: external-secrets.io
          kind: ExternalSecret
          jsonPointers:
            - /spec/target/deletionPolicy
          jqPathExpressions:
            - .spec.data[].remoteRef.conversionStrategy
            - .spec.data[].remoteRef.decodingStrategy
            - .spec.data[].remoteRef.metadataPolicy
            - .spec.data[].remoteRef.nullBytePolicy
```

- [ ] **Step 3.4: Inspect root-app.yaml — does it auto-discover new ApplicationSets?**

```bash
cat gitops/bootstrap/root-app.yaml
```

Inspect whether the root-app's source path is `gitops/bootstrap/applicationsets/` (auto-discovers all yaml files in there) or names individual files. If it auto-discovers (typical pattern), the new appset will be picked up automatically. If it names individual files, add `observability.yaml` to its list.

- [ ] **Step 3.5: yamllint**

```bash
yamllint gitops/bootstrap/applicationsets/observability.yaml
```

- [ ] **Step 3.6: kubeconform on the file directly (it's a static manifest, not Helm-rendered)**

```bash
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  gitops/bootstrap/applicationsets/observability.yaml
# Expect: 0 invalid resources (ApplicationSet schema available via the CRD catalog).
```

- [ ] **Step 3.7: Commit, push, open PR**

```bash
git add gitops/bootstrap/applicationsets/observability.yaml
git commit -m "$(cat <<'EOF'
feat(gitops): add observability ApplicationSet (empty tier)

Adds bootstrap/applicationsets/observability.yaml — clone of
platform.yaml retargeted at gitops/apps/observability/*. The
directory glob matches nothing yet, so the ApplicationSet
generates 0 child Applications. Subsequent PRs (4-7) drop
wrapper charts into the new tier and ArgoCD picks them up
automatically.

Same syncPolicy + ignoreDifferences block as platform.yaml.
ignoreDifferences carries forward the ESO-default drift filter
established in PRs #119/#127 — observability's Grafana ESO
will inherit it.

PR 3 of 8 in sub-project #5 (observability).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin feat/gitops-observability-appset

gh pr create --title "feat(gitops): observability ApplicationSet (empty tier)" --body "$(cat <<'EOF'
## Summary
- New ApplicationSet \`observability-apps\` watching \`gitops/apps/observability/*\`
- 0 child Applications generated (directory empty until PR 4)
- Reuses platform.yaml's syncPolicy + ESO ignoreDifferences pattern

## Test plan
- [ ] CI yamllint + kubeconform pass
- [ ] After merge: \`kubectl -n argocd get appset observability-apps\` exists
- [ ] After merge: 0 child Applications generated (directory still empty)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3.8: STOP — wait for user to merge**

- [ ] **Step 3.9: Post-merge verification**

```bash
git checkout main && git pull

kubectl -n argocd get appset observability-apps
# Expect: appset exists, GENERATED column says "0 / 0".

# Confirm no child Applications generated (directory empty):
kubectl -n argocd get app -l argocd.argoproj.io/instance=observability-apps
# Expect: No resources found (appset matches empty glob).
```

---

## Task 4: PR 4 — `observability/prometheus-operator-crds`

Installs the prometheus-operator CRDs (CRDs only, no controller) cluster-wide so upstream charts that ship `serviceMonitor.enabled: true` / `podMonitor.enabled: true` can render their `ServiceMonitor`/`PodMonitor`/`PrometheusRule` resources. vm-operator (Task 5) auto-discovers these and translates them into vmagent scrape config.

**Files:**
- Create: `gitops/apps/observability/prometheus-operator-crds/Chart.yaml`
- Create: `gitops/apps/observability/prometheus-operator-crds/values.yaml`
- Create: `gitops/apps/observability/prometheus-operator-crds/.helmignore`
- Create: `gitops/apps/observability/prometheus-operator-crds/templates/namespace.yaml`

- [ ] **Step 4.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-prometheus-operator-crds
```

- [ ] **Step 4.2: Create directory structure**

```bash
mkdir -p gitops/apps/observability/prometheus-operator-crds/templates
```

- [ ] **Step 4.3: Write `gitops/apps/observability/prometheus-operator-crds/Chart.yaml`**

```yaml
apiVersion: v2
name: prometheus-operator-crds-wrapper
description: Wrapper chart for prometheus-operator CRDs (no controller) — enables ServiceMonitor/PodMonitor/PrometheusRule cluster-wide
type: application
version: 0.1.0
appVersion: "0.78.0"
dependencies:
  - name: prometheus-operator-crds
    version: 18.0.1
    repository: https://prometheus-community.github.io/helm-charts
```

If a newer 18.x is current at impl time, bump within the same major.

- [ ] **Step 4.4: Write `gitops/apps/observability/prometheus-operator-crds/.helmignore`**

```
.git/
.gitignore
.DS_Store
*.swp
*.swo
*~
```

- [ ] **Step 4.5: Write `gitops/apps/observability/prometheus-operator-crds/values.yaml`**

```yaml
# CRD-only chart — no controller, no values to tune. Empty is correct.
prometheus-operator-crds: {}
```

- [ ] **Step 4.6: Write `gitops/apps/observability/prometheus-operator-crds/templates/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prometheus-operator-crds
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

- [ ] **Step 4.7: Helm dependency update + render**

```bash
helm dependency update gitops/apps/observability/prometheus-operator-crds/
ls gitops/apps/observability/prometheus-operator-crds/charts/
# Expect: prometheus-operator-crds-18.x.x.tgz

helm template poc gitops/apps/observability/prometheus-operator-crds/ > /tmp/poc-render.yaml
grep '^kind: CustomResourceDefinition' /tmp/poc-render.yaml | wc -l
# Expect: 9 (CRDs: Alertmanager, AlertmanagerConfig, PodMonitor, Probe, Prometheus, PrometheusAgent, PrometheusRule, ScrapeConfig, ServiceMonitor, ThanosRuler).
# (Some chart versions may pack 10-11 CRDs. >=8 is healthy.)
```

- [ ] **Step 4.8: kubeconform + yamllint**

```bash
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  /tmp/poc-render.yaml

yamllint gitops/apps/observability/prometheus-operator-crds/
```

- [ ] **Step 4.9: Commit, push, open PR**

```bash
git add gitops/apps/observability/prometheus-operator-crds/
git commit -m "$(cat <<'EOF'
feat(observability): prometheus-operator CRDs (no controller)

Installs the Prometheus Operator CRDs cluster-wide (CRDs only —
no controller), so upstream charts that ship
serviceMonitor.enabled: true / podMonitor.enabled: true can
render their ServiceMonitor / PodMonitor / PrometheusRule
resources. vm-operator (PR 5) auto-discovers these and
translates them into vmagent scrape config alongside its own
VM-prefixed CRDs.

First app in the new observability tier (the appset itself
landed in PR 3).

PR 4 of 8 in sub-project #5 (observability).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin feat/gitops-prometheus-operator-crds

gh pr create --title "feat(observability): prometheus-operator CRDs" --body "$(cat <<'EOF'
## Summary
- New observability-tier app: \`gitops/apps/observability/prometheus-operator-crds/\`
- CRDs only — no controller (no Prometheus, no Alertmanager)
- Enables \`serviceMonitor.enabled: true\` toggles on upstream charts cluster-wide

## Test plan
- [ ] CI helm template renders cleanly with ~9 CRDs
- [ ] After merge: \`kubectl -n argocd get app prometheus-operator-crds\` Synced/Healthy
- [ ] After merge: \`kubectl get crd servicemonitors.monitoring.coreos.com\` exists
- [ ] After merge: \`kubectl get crd podmonitors.monitoring.coreos.com\` exists

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4.10: STOP — wait for user to merge**

- [ ] **Step 4.11: Post-merge verification**

```bash
git checkout main && git pull

kubectl -n argocd get app prometheus-operator-crds
# Expect: Synced/Healthy

kubectl get crd servicemonitors.monitoring.coreos.com podmonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com alertmanagers.monitoring.coreos.com
# Expect: 4 CRDs Established.

kubectl -n argocd get appset observability-apps
# Expect: GENERATED column shows 1 / 1 (one Application).
```

---

## Task 5: PR 5 — `observability/vm-system` (vm-operator + VMSingle + VMAgent)

Deploys the VictoriaMetrics operator chart, plus a `VMSingle` (single-node TSDB, 30d retention, 40 Gi local-path) and a `VMAgent` (single replica, 5 Gi WAL on local-path) defined as CRD instances in the same wrapper. Includes two `VMNodeScrape` resources for kubelet + cAdvisor.

**Files:**
- Create: `gitops/apps/observability/vm-system/Chart.yaml`
- Create: `gitops/apps/observability/vm-system/values.yaml`
- Create: `gitops/apps/observability/vm-system/.helmignore`
- Create: `gitops/apps/observability/vm-system/templates/namespace.yaml`
- Create: `gitops/apps/observability/vm-system/templates/vmsingle.yaml`
- Create: `gitops/apps/observability/vm-system/templates/vmagent.yaml`
- Create: `gitops/apps/observability/vm-system/templates/vmnodescrape-kubelet.yaml`
- Create: `gitops/apps/observability/vm-system/templates/vmnodescrape-cadvisor.yaml`
- Create: `gitops/apps/observability/vm-system/templates/vmservicescrape-self.yaml`

- [ ] **Step 5.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-vm-system
```

- [ ] **Step 5.2: Create directory structure**

```bash
mkdir -p gitops/apps/observability/vm-system/templates
```

- [ ] **Step 5.3: Write `gitops/apps/observability/vm-system/Chart.yaml`**

```yaml
apiVersion: v2
name: vm-system-wrapper
description: VictoriaMetrics operator + VMSingle (TSDB) + VMAgent (scraper) + cluster-wide kubelet/cAdvisor scrapes
type: application
version: 0.1.0
appVersion: "0.49.0"
dependencies:
  - name: victoria-metrics-operator
    version: 0.49.0
    repository: https://victoriametrics.github.io/helm-charts/
```

If a newer 0.x is current at impl time, bump within the same major.

- [ ] **Step 5.4: Write `gitops/apps/observability/vm-system/.helmignore`**

```
.git/
.gitignore
.DS_Store
*.swp
*.swo
*~
```

- [ ] **Step 5.5: Write `gitops/apps/observability/vm-system/values.yaml`**

```yaml
victoria-metrics-operator:
  # CRDs ship with the chart; install them. vm-operator's CRDs include
  # VMSingle, VMAgent, VMServiceScrape, VMPodScrape, VMNodeScrape, VMRule.
  crds:
    create: true

  operator:
    # Enable converters from prometheus-operator CRDs:
    enable_converter_owner_references: true
    disable_prometheus_converter: false

  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 256Mi
```

- [ ] **Step 5.6: Write `gitops/apps/observability/vm-system/templates/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vm-system
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

- [ ] **Step 5.7: Write `gitops/apps/observability/vm-system/templates/vmsingle.yaml`**

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMSingle
metadata:
  name: vmsingle-chalupa
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "10"
spec:
  retentionPeriod: "30d"
  replicaCount: 1
  storage:
    accessModes: [ReadWriteOnce]
    storageClassName: local-path
    resources:
      requests:
        storage: 40Gi
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 100m
      memory: 256Mi
  livenessProbe:
    httpGet:
      path: /health
      port: 8429
    timeoutSeconds: 5
    periodSeconds: 30
  readinessProbe:
    httpGet:
      path: /health
      port: 8429
    timeoutSeconds: 5
    periodSeconds: 10
```

(sync-wave 10 ensures vmsingle is created after the operator's CRDs and the operator pod itself reach steady state.)

- [ ] **Step 5.8: Write `gitops/apps/observability/vm-system/templates/vmagent.yaml`**

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAgent
metadata:
  name: vmagent-chalupa
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "20"
spec:
  replicaCount: 1
  scrapeInterval: 30s
  remoteWrite:
    - url: http://vmsingle-vmsingle-chalupa.vm-system.svc.cluster.local:8429/api/v1/write

  # Discover all scrape CRDs cluster-wide (both VM-native and prometheus-operator-CRD form).
  selectAllByDefault: true
  serviceScrapeNamespaceSelector: {}
  serviceScrapeSelector: {}
  podScrapeNamespaceSelector: {}
  podScrapeSelector: {}
  nodeScrapeNamespaceSelector: {}
  nodeScrapeSelector: {}
  staticScrapeNamespaceSelector: {}
  staticScrapeSelector: {}
  probeNamespaceSelector: {}
  probeSelector: {}

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 100m
      memory: 256Mi

  extraArgs:
    remoteWrite.tmpDataPath: /tmp/vmagent
    promscrape.streamParse: "true"

  # WAL buffer for samples queued during vmsingle outages.
  statefulMode: true
  statefulStorage:
    accessModes: [ReadWriteOnce]
    storageClassName: local-path
    resources:
      requests:
        storage: 5Gi

  livenessProbe:
    httpGet:
      path: /health
      port: 8429
    timeoutSeconds: 5
  readinessProbe:
    httpGet:
      path: /health
      port: 8429
    timeoutSeconds: 5
```

(sync-wave 20 ensures vmsingle is up before vmagent tries to remote-write. `statefulMode: true` makes vmagent a StatefulSet with a per-pod PVC, so the WAL persists across restarts.)

- [ ] **Step 5.9: Write `gitops/apps/observability/vm-system/templates/vmnodescrape-kubelet.yaml`**

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMNodeScrape
metadata:
  name: kubelet
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  scheme: https
  scrapeInterval: 30s
  scrapeTimeout: 10s
  honorLabels: true
  tlsConfig:
    insecureSkipVerify: true
  bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
  relabelConfigs:
    - action: labelmap
      regex: __meta_kubernetes_node_label_(.+)
    - sourceLabels: [__metrics_path__]
      targetLabel: metrics_path
```

- [ ] **Step 5.10: Write `gitops/apps/observability/vm-system/templates/vmnodescrape-cadvisor.yaml`**

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMNodeScrape
metadata:
  name: cadvisor
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  scheme: https
  path: /metrics/cadvisor
  scrapeInterval: 30s
  scrapeTimeout: 10s
  honorLabels: true
  tlsConfig:
    insecureSkipVerify: true
  bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
  relabelConfigs:
    - action: labelmap
      regex: __meta_kubernetes_node_label_(.+)
```

- [ ] **Step 5.11: Write `gitops/apps/observability/vm-system/templates/vmservicescrape-self.yaml`**

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: vmsingle-self
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: vmsingle
  namespaceSelector:
    matchNames: [vm-system]
  endpoints:
    - port: http
      interval: 30s
---
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: vmagent-self
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: vmagent
  namespaceSelector:
    matchNames: [vm-system]
  endpoints:
    - port: http
      interval: 30s
```

- [ ] **Step 5.12: Helm dependency update**

```bash
helm dependency update gitops/apps/observability/vm-system/
ls gitops/apps/observability/vm-system/charts/
# Expect: victoria-metrics-operator-0.49.x.tgz
```

- [ ] **Step 5.13: Render + validate**

```bash
helm template vm-system gitops/apps/observability/vm-system/ > /tmp/vm-render.yaml
wc -l /tmp/vm-render.yaml
# Expect: ~3000-5000 lines (operator chart is big — many CRDs).

# vm-operator's CRDs are in the chart and not in kubeconform's default catalog.
# Use lenient mode + skip the VM-CRD kinds for validation:
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/vm-render.yaml | tail -5
# Expect: 0 invalid (some "skipped" lines for VMSingle/VMAgent/VMServiceScrape/VMNodeScrape are fine — operator validates at runtime).

yamllint gitops/apps/observability/vm-system/
```

- [ ] **Step 5.14: Verify the VM CRD instances render correctly**

```bash
grep -A5 'kind: VMSingle' /tmp/vm-render.yaml | head -20
grep -A5 'kind: VMAgent' /tmp/vm-render.yaml | head -20
# Expect: each has spec block with retentionPeriod / replicaCount / storage etc.

grep -c 'kind: VMNodeScrape' /tmp/vm-render.yaml
# Expect: 2

grep -c 'kind: VMServiceScrape' /tmp/vm-render.yaml
# Expect: 2 (vmsingle-self, vmagent-self)
```

- [ ] **Step 5.15: Commit, push, open PR**

```bash
git add gitops/apps/observability/vm-system/
git commit -m "$(cat <<'EOF'
feat(observability): VictoriaMetrics — operator + VMSingle + VMAgent

Deploys the VM ecosystem core:
- victoria-metrics-operator chart 0.49.x (CRDs + controller)
- VMSingle: single-node TSDB, 30d retention, 40 Gi local-path PVC,
  Guaranteed QoS (100m CPU / 256Mi RAM)
- VMAgent: 1 replica, statefulMode (5 Gi local-path WAL),
  selectAllByDefault discovers all VMScrape and prometheus-operator
  ServiceMonitor/PodMonitor CRDs cluster-wide
- VMNodeScrape kubelet + cadvisor (TLS skip + sa bearer token,
  Talos-style)
- VMServiceScrape vmsingle-self + vmagent-self

sync-waves: namespace -1, operator default (0), VMSingle 10,
VMAgent 20, scrape CRDs 30 — ensures CRDs exist before instances
and vmsingle is up before vmagent remote-writes.

PR 5 of 8 in sub-project #5 (observability).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin feat/gitops-vm-system

gh pr create --title "feat(observability): VictoriaMetrics — operator + VMSingle + VMAgent" --body "$(cat <<'EOF'
## Summary
- vm-operator chart + VMSingle (40 Gi, 30d retention) + VMAgent (5 Gi WAL)
- 2 VMNodeScrape (kubelet + cAdvisor on every node)
- 2 VMServiceScrape (vmsingle + vmagent self-scrape)
- selectAllByDefault discovers all scrape CRDs cluster-wide

## Test plan
- [ ] CI helm template renders cleanly
- [ ] After merge: \`kubectl -n argocd get app vm-system\` Synced/Healthy
- [ ] After merge: \`kubectl -n vm-system get pods\` shows 3 Running pods (operator + vmsingle-* + vmagent-*)
- [ ] After merge: vmagent /targets shows kubelet + cAdvisor jobs UP across all 6 nodes
- [ ] After merge: \`argocd-repo-server\` memory under limit (PR #131 reference — vm-system chart bundle is large)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5.16: STOP — wait for user to merge**

- [ ] **Step 5.17: Post-merge verification (extensive — this is the foundation)**

```bash
git checkout main && git pull

kubectl -n argocd get app vm-system
# Expect: Synced/Healthy

kubectl -n vm-system get pods
# Expect: 3 pods Running:
#   - vm-operator-* (operator)
#   - vmsingle-vmsingle-chalupa-0 (StatefulSet, single replica)
#   - vmagent-vmagent-chalupa-0 (StatefulSet, single replica due to statefulMode: true)

kubectl -n vm-system get pvc
# Expect: 2 PVCs Bound: vmsingle-vmsingle-chalupa (40Gi), vmagent-vmagent-chalupa-0 (5Gi)

# argocd-repo-server health:
kubectl -n argocd top pods | grep repo-server
# Expect: usage well under limit (limit was bumped in PR #131; should still be fine).
# If repo-server OOMs, raise its memory request via a follow-up PR similar to #131.

# vmagent target discovery:
kubectl -n vm-system port-forward svc/vmagent-vmagent-chalupa 8429:8429 &
PF_PID=$!
sleep 3

# Check kubelet + cAdvisor scrapes are healthy:
curl -s http://localhost:8429/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="kubelet" or .labels.job=="cadvisor") | {job: .labels.job, instance: .labels.instance, health: .health}'
# Expect: 12 entries (6 nodes × 2 jobs), all health="up".

# Vmsingle has data:
curl -s 'http://localhost:8429/api/v1/query?query=up' | jq '.data.result | length'
# Expect: > 10 series.

curl -s 'http://localhost:8429/api/v1/query?query=count(up)' | jq '.data.result[0].value[1]'
# Expect: a numeric string > 10.

kill $PF_PID

# vmsingle's own /metrics is also exposed:
kubectl -n vm-system port-forward svc/vmsingle-vmsingle-chalupa 8430:8429 &
PF_PID=$!
sleep 2
curl -s http://localhost:8430/api/v1/status/tsdb | jq '.data.headStats.numSeries'
# Expect: a positive integer.
kill $PF_PID
```

If any check fails (especially `argocd-repo-server` OOM), bump its memory similarly to PR #131 in a small follow-up PR before continuing to Task 6.

---

## Task 6: PR 6 — `observability/kube-state-metrics` + `observability/node-exporter`

Two small wrapper charts. Both ship `serviceMonitor.enabled: true` toggles that vmagent picks up automatically (via prometheus-operator-crds installed in PR 4).

**Files:**
- Create: `gitops/apps/observability/kube-state-metrics/Chart.yaml`
- Create: `gitops/apps/observability/kube-state-metrics/values.yaml`
- Create: `gitops/apps/observability/kube-state-metrics/.helmignore`
- Create: `gitops/apps/observability/kube-state-metrics/templates/namespace.yaml`
- Create: `gitops/apps/observability/node-exporter/Chart.yaml`
- Create: `gitops/apps/observability/node-exporter/values.yaml`
- Create: `gitops/apps/observability/node-exporter/.helmignore`
- Create: `gitops/apps/observability/node-exporter/templates/namespace.yaml`

- [ ] **Step 6.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-ksm-and-node-exporter
```

- [ ] **Step 6.2: Create directory structures**

```bash
mkdir -p gitops/apps/observability/kube-state-metrics/templates
mkdir -p gitops/apps/observability/node-exporter/templates
```

- [ ] **Step 6.3: Write `gitops/apps/observability/kube-state-metrics/Chart.yaml`**

```yaml
apiVersion: v2
name: kube-state-metrics-wrapper
description: Wrapper chart for kube-state-metrics (Pod/Deployment/Node object-state metrics)
type: application
version: 0.1.0
appVersion: "2.13.0"
dependencies:
  - name: kube-state-metrics
    version: 5.27.0
    repository: https://prometheus-community.github.io/helm-charts
```

- [ ] **Step 6.4: Write `gitops/apps/observability/kube-state-metrics/.helmignore`**

```
.git/
.gitignore
.DS_Store
*.swp
*.swo
*~
```

- [ ] **Step 6.5: Write `gitops/apps/observability/kube-state-metrics/values.yaml`**

```yaml
kube-state-metrics:
  replicas: 1

  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 256Mi

  prometheus:
    monitor:
      enabled: true   # creates a ServiceMonitor; vmagent picks it up
      interval: 30s

  selfMonitor:
    enabled: false
```

- [ ] **Step 6.6: Write `gitops/apps/observability/kube-state-metrics/templates/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kube-state-metrics
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

- [ ] **Step 6.7: Write `gitops/apps/observability/node-exporter/Chart.yaml`**

```yaml
apiVersion: v2
name: node-exporter-wrapper
description: Wrapper chart for prometheus-node-exporter (per-node CPU/RAM/disk/network metrics, workers only)
type: application
version: 0.1.0
appVersion: "1.8.2"
dependencies:
  - name: prometheus-node-exporter
    version: 4.40.0
    repository: https://prometheus-community.github.io/helm-charts
```

- [ ] **Step 6.8: Write `gitops/apps/observability/node-exporter/.helmignore`**

```
.git/
.gitignore
.DS_Store
*.swp
*.swo
*~
```

- [ ] **Step 6.9: Write `gitops/apps/observability/node-exporter/values.yaml`**

```yaml
prometheus-node-exporter:
  # DaemonSet — one pod per node. By default does NOT tolerate the
  # control-plane NoSchedule taint, so node-exporter runs on workers only
  # (the design choice for sub-project #5; CPs run no workloads anyway).
  hostNetwork: true
  hostPID: true

  service:
    port: 9100
    targetPort: 9100

  prometheus:
    monitor:
      enabled: true   # creates a ServiceMonitor; vmagent picks it up
      interval: 30s

  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 50m
      memory: 64Mi  # Guaranteed QoS — small DaemonSet workload

  # Exclude virtual / pseudo filesystems from disk metrics; reduce noise.
  extraArgs:
    - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/.+)($|/)
    - --collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$
```

- [ ] **Step 6.10: Write `gitops/apps/observability/node-exporter/templates/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: node-exporter
  labels:
    # Privileged PSA: node-exporter uses hostNetwork + hostPID, mounts /proc and /sys.
    # Per the Talos PSA pattern, namespaces with hostNetwork/hostPID need privileged.
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

- [ ] **Step 6.11: Helm dependency update for both**

```bash
helm dependency update gitops/apps/observability/kube-state-metrics/
ls gitops/apps/observability/kube-state-metrics/charts/
# Expect: kube-state-metrics-5.27.x.tgz

helm dependency update gitops/apps/observability/node-exporter/
ls gitops/apps/observability/node-exporter/charts/
# Expect: prometheus-node-exporter-4.40.x.tgz
```

- [ ] **Step 6.12: Render + validate both**

```bash
helm template ksm gitops/apps/observability/kube-state-metrics/ > /tmp/ksm-render.yaml
helm template ne  gitops/apps/observability/node-exporter/ > /tmp/ne-render.yaml

kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/ksm-render.yaml /tmp/ne-render.yaml

# Confirm ServiceMonitors are present:
grep -c 'kind: ServiceMonitor' /tmp/ksm-render.yaml
# Expect: 1

grep -c 'kind: ServiceMonitor' /tmp/ne-render.yaml
# Expect: 1

yamllint gitops/apps/observability/kube-state-metrics/
yamllint gitops/apps/observability/node-exporter/
```

- [ ] **Step 6.13: Commit, push, open PR**

```bash
git add gitops/apps/observability/kube-state-metrics/ gitops/apps/observability/node-exporter/
git commit -m "$(cat <<'EOF'
feat(observability): kube-state-metrics + node-exporter

Two small wrapper charts in the observability tier:
- kube-state-metrics 5.27.x — Pod/Deployment/Node object-state
  metrics. ServiceMonitor enabled; vmagent auto-discovers.
- prometheus-node-exporter 4.40.x — per-node CPU/RAM/disk/network
  metrics as a DaemonSet. workers-only (no CP toleration);
  hostNetwork + hostPID; namespace gets privileged PSA per the
  Talos PSA pattern.

Both rely on prometheus-operator-crds (PR 4) to render their
ServiceMonitor resources. vm-operator's selectAllByDefault
(PR 5) auto-translates the ServiceMonitors into vmagent scrape
config.

PR 6 of 8 in sub-project #5 (observability).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin feat/gitops-ksm-and-node-exporter

gh pr create --title "feat(observability): kube-state-metrics + node-exporter" --body "$(cat <<'EOF'
## Summary
- New observability-tier app: \`kube-state-metrics\` (chart 5.27.x)
- New observability-tier app: \`node-exporter\` (chart 4.40.x, DaemonSet, workers-only)
- Both ship \`prometheus.monitor.enabled: true\` ServiceMonitors
- node-exporter namespace gets privileged PSA (hostNetwork/hostPID)

## Test plan
- [ ] CI helm template renders cleanly for both
- [ ] After merge: 2 new Applications Synced/Healthy
- [ ] \`kubectl -n kube-state-metrics get pods\` — 1 Running
- [ ] \`kubectl -n node-exporter get pods\` — 3 Running (one per worker, DaemonSet)
- [ ] vmagent /targets shows ksm + node-exporter jobs UP

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 6.14: STOP — wait for user to merge**

- [ ] **Step 6.15: Post-merge verification**

```bash
git checkout main && git pull

kubectl -n argocd get app kube-state-metrics node-exporter
# Expect: both Synced/Healthy

kubectl -n kube-state-metrics get pods
# Expect: kube-state-metrics-* 1/1 Running

kubectl -n node-exporter get pods
# Expect: 3 pods Running (one per worker — DaemonSet doesn't tolerate CP taint).

kubectl get servicemonitor -A | grep -E '(kube-state-metrics|node-exporter)'
# Expect: 2 rows (one in each ns).

# vmagent picked them up:
kubectl -n vm-system port-forward svc/vmagent-vmagent-chalupa 8429:8429 &
PF_PID=$!
sleep 3

curl -s http://localhost:8429/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="kube-state-metrics" or .labels.job=="node-exporter") | {job: .labels.job, instance: .labels.instance, health: .health}'
# Expect: 4 entries (1 ksm + 3 node-exporters), all health="up".

# Sample queries return data:
curl -s 'http://localhost:8429/api/v1/query?query=kube_pod_info' | jq '.data.result | length'
# Expect: > 30 (one per pod cluster-wide).

curl -s 'http://localhost:8429/api/v1/query?query=node_memory_MemTotal_bytes' | jq '.data.result | length'
# Expect: 3 (one per worker).

kill $PF_PID
```

---

## Task 7: Operator Runbook — Seed Grafana admin in OpenBao + extend ESO policy

**This is a manual operator runbook step. NO PR is produced. Do this BEFORE Task 8.**

Sub-project #5 needs OpenBao to hold Grafana's admin credentials. ESO will sync them into the `grafana` namespace as a K8s Secret consumed by the Grafana chart's `admin.existingSecret`.

**Operator prerequisites:**
- Access to `~/secure/openbao-init.json` (or 1Password "OpenBao Init") — has the root token.
- LAN reachability to `https://openbao.frame.chalupatech.com` (the OpenBao UI).

- [ ] **Step 7.1: Verify OpenBao is unsealed**

```bash
kubectl -n openbao exec openbao-0 -- bao status
# Expect: Sealed=false. If Sealed=true, run ./scripts/openbao/unseal.sh first.
```

- [ ] **Step 7.2: Open the OpenBao UI and log in with the root token**

Visit `https://openbao.frame.chalupatech.com/` (LAN-only). Log in with the `root_token` from `~/secure/openbao-init.json`.

- [ ] **Step 7.3: Generate a strong admin password**

```bash
GRAFANA_ADMIN_PASS=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)
echo "Grafana admin password: $GRAFANA_ADMIN_PASS"
# Save this to your password manager (1Password) — needed once after Task 8 completes for first login.
```

- [ ] **Step 7.4: In the OpenBao UI, create the secret at `secret/grafana/admin`**

UI path: Secrets → kv → `secret/` → Create secret → Path: `grafana/admin`

Fields:
- `admin-user`: `admin`
- `admin-password`: (paste `$GRAFANA_ADMIN_PASS` from Step 7.3)

Save.

- [ ] **Step 7.5: Verify via CLI**

```bash
kubectl -n openbao exec openbao-0 -- bao kv get secret/grafana/admin
# Expect: prints both fields. password should match what you set.
```

- [ ] **Step 7.6: Extend the ESO Vault role's policies to allow `secret/data/grafana/*`**

Either via OpenBao UI (Policies → `external-secrets` → Edit) or CLI:

```bash
# Read current policy:
kubectl -n openbao exec openbao-0 -- bao policy read external-secrets > /tmp/eso-policy.hcl
cat /tmp/eso-policy.hcl
```

Inspect: confirm it currently lists `cloudflare-read`-style + `media-read`-style paths. There should already be lines like:

```hcl
path "secret/data/cloudflare/*" { capabilities = ["read"] }
path "secret/data/nzbget/*"     { capabilities = ["read"] }
path "secret/data/sonarr/*"     { capabilities = ["read"] }
path "secret/data/radarr/*"     { capabilities = ["read"] }
path "secret/data/seerr/*"      { capabilities = ["read"] }
path "secret/data/tdarr/*"      { capabilities = ["read"] }
path "secret/data/postgres/*"   { capabilities = ["read"] }
```

Append a new line for grafana:

```hcl
path "secret/data/grafana/*"    { capabilities = ["read"] }
```

Re-write the policy:

```bash
# Edit /tmp/eso-policy.hcl to add the grafana line, then:
kubectl -n openbao exec -i openbao-0 -- bao policy write external-secrets - < /tmp/eso-policy.hcl
# Expect: Success! Uploaded policy: external-secrets
```

- [ ] **Step 7.7: Verify the policy update**

```bash
kubectl -n openbao exec openbao-0 -- bao policy read external-secrets | grep grafana
# Expect: path "secret/data/grafana/*" { capabilities = ["read"] }
```

- [ ] **Step 7.8: No PR. Record the operator action in your homelab ops log**

This step is operator-side only — no Git change. Record completion (date, password manager entry name) in your personal ops log so future operators know it's done.

Once verified, proceed to Task 8.

---

## Task 8: PR 7 — `observability/grafana` (chart + IngressRoute + admin ESO + datasource + 8 dashboards)

The biggest PR in the plan. Deploys Grafana with HTTPS at `grafana.frame.chalupatech.com`, anonymous-readonly + admin from OpenBao via ESO, the VictoriaMetrics datasource auto-provisioned, and 8 starter dashboards loaded via the sidecar.

**Files:**
- Create: `gitops/apps/observability/grafana/Chart.yaml`
- Create: `gitops/apps/observability/grafana/values.yaml`
- Create: `gitops/apps/observability/grafana/.helmignore`
- Create: `gitops/apps/observability/grafana/templates/namespace.yaml`
- Create: `gitops/apps/observability/grafana/templates/ingressroute.yaml`
- Create: `gitops/apps/observability/grafana/templates/grafana-admin-externalsecret.yaml`
- Create: `gitops/apps/observability/grafana/templates/datasource-vmsingle.yaml`
- Create: `gitops/apps/observability/grafana/templates/dashboards/1860-node-exporter-full.yaml`
- Create: `gitops/apps/observability/grafana/templates/dashboards/13770-kubernetes-views-global.yaml`
- Create: `gitops/apps/observability/grafana/templates/dashboards/13332-kubernetes-views-pods.yaml`
- Create: `gitops/apps/observability/grafana/templates/dashboards/14584-argocd.yaml`
- Create: `gitops/apps/observability/grafana/templates/dashboards/17346-traefik-2.yaml`
- Create: `gitops/apps/observability/grafana/templates/dashboards/20417-cloudnativepg.yaml`
- Create: `gitops/apps/observability/grafana/templates/dashboards/12683-victoriametrics-single.yaml`
- Create: `gitops/apps/observability/grafana/templates/dashboards/12693-vmagent.yaml`
- Create: `gitops/apps/observability/grafana/dashboards/<id>-<slug>.json` (8 files)

- [ ] **Step 8.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-grafana
```

- [ ] **Step 8.2: Create directory structure**

```bash
mkdir -p gitops/apps/observability/grafana/templates/dashboards
mkdir -p gitops/apps/observability/grafana/dashboards
```

- [ ] **Step 8.3: Write `gitops/apps/observability/grafana/Chart.yaml`**

```yaml
apiVersion: v2
name: grafana-wrapper
description: Wrapper chart for Grafana — anonymous-readonly + admin from OpenBao via ESO, IngressRoute on grafana.frame.chalupatech.com, VictoriaMetrics datasource, 8 starter dashboards loaded via sidecar
type: application
version: 0.1.0
appVersion: "11.4.0"
dependencies:
  - name: grafana
    version: 8.6.0
    repository: https://grafana.github.io/helm-charts
```

If a newer 8.x is current at impl time, bump within the same major.

- [ ] **Step 8.4: Write `gitops/apps/observability/grafana/.helmignore`**

```
.git/
.gitignore
.DS_Store
*.swp
*.swo
*~
```

(Note: do NOT exclude `dashboards/` — those JSON files are loaded by `.Files.Get` and must be packed into the chart.)

- [ ] **Step 8.5: Write `gitops/apps/observability/grafana/values.yaml`**

```yaml
grafana:
  replicas: 1

  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password

  persistence:
    enabled: true
    size: 5Gi
    storageClassName: local-path
    accessModes: [ReadWriteOnce]

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi

  livenessProbe:
    httpGet:
      path: /api/health
      port: 3000
    timeoutSeconds: 5
    periodSeconds: 30
  readinessProbe:
    httpGet:
      path: /api/health
      port: 3000
    timeoutSeconds: 5
    periodSeconds: 10

  # Anonymous read-only + admin from existingSecret (decision e of the spec).
  grafana.ini:
    auth.anonymous:
      enabled: true
      org_role: Viewer
    auth:
      disable_login_form: false   # admin login still works
    server:
      root_url: https://grafana.frame.chalupatech.com/
      domain: grafana.frame.chalupatech.com
    analytics:
      reporting_enabled: false
      check_for_updates: false

  # Sidecar — auto-loads ConfigMap-backed datasources and dashboards labelled
  # grafana_datasource: "1" / grafana_dashboard: "1".
  sidecar:
    datasources:
      enabled: true
      label: grafana_datasource
      labelValue: "1"
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      folder: /tmp/dashboards
      provider:
        foldersFromFilesStructure: false

  # Self-scrape — gives vmagent a target for grafana itself.
  serviceMonitor:
    enabled: true
    interval: 30s

  # Disable the default password generation; we use existingSecret.
  testFramework:
    enabled: false
```

- [ ] **Step 8.6: Write `gitops/apps/observability/grafana/templates/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: grafana
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

- [ ] **Step 8.7: Write `gitops/apps/observability/grafana/templates/grafana-admin-externalsecret.yaml`**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-admin-creds
  namespace: grafana
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: grafana-admin
    creationPolicy: Owner
  data:
    - secretKey: admin-user
      remoteRef:
        key: secret/grafana/admin
        property: admin-user
    - secretKey: admin-password
      remoteRef:
        key: secret/grafana/admin
        property: admin-password
```

(Per memory: ESO version on cluster only serves `external-secrets.io/v1`, NOT `v1beta1`. Do not use `v1beta1`.)

- [ ] **Step 8.8: Write `gitops/apps/observability/grafana/templates/ingressroute.yaml`**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
  namespace: grafana
  annotations:
    # MANDATORY per memory — without this annotation, external-dns silently
    # skips the route and the Cloudflare A record never appears.
    external-dns.alpha.kubernetes.io/target: "192.168.1.230"
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`grafana.frame.chalupatech.com`)
      kind: Rule
      services:
        - name: grafana
          port: 80
  tls: {}   # uses the default Traefik TLSStore wildcard *.frame.chalupatech.com from #2
```

- [ ] **Step 8.9: Write `gitops/apps/observability/grafana/templates/datasource-vmsingle.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-vmsingle
  namespace: grafana
  labels:
    grafana_datasource: "1"
data:
  vmsingle.yaml: |
    apiVersion: 1
    datasources:
      - name: VictoriaMetrics
        type: prometheus
        access: proxy
        url: http://vmsingle-vmsingle-chalupa.vm-system.svc.cluster.local:8429
        isDefault: true
        editable: false
        jsonData:
          httpMethod: POST
          prometheusType: Prometheus
          prometheusVersion: "2.40.0"
```

- [ ] **Step 8.10: Download the 8 starter dashboards**

Each dashboard is fetched from grafana.com's API. Use the latest revision available at impl time. Save under `gitops/apps/observability/grafana/dashboards/`.

```bash
DASHBOARDS=(
  "1860:node-exporter-full"
  "13770:kubernetes-views-global"
  "13332:kubernetes-views-pods"
  "14584:argocd"
  "17346:traefik-2"
  "20417:cloudnativepg"
  "12683:victoriametrics-single"
  "12693:vmagent"
)

cd gitops/apps/observability/grafana/dashboards/

for entry in "${DASHBOARDS[@]}"; do
  ID="${entry%%:*}"
  SLUG="${entry##*:}"

  # Find the latest revision:
  LATEST_REV=$(curl -sS "https://grafana.com/api/dashboards/$ID" | jq -r '.revision')
  echo "Dashboard $ID ($SLUG) → revision $LATEST_REV"

  # Download:
  curl -sS "https://grafana.com/api/dashboards/$ID/revisions/$LATEST_REV/download" \
    -o "${ID}-${SLUG}.json"

  # Verify it's valid JSON:
  jq -e . "${ID}-${SLUG}.json" >/dev/null && echo "  OK"
done

cd -

ls gitops/apps/observability/grafana/dashboards/
# Expect: 8 .json files.
```

If any download fails or returns invalid JSON, retry; some dashboards on grafana.com have been delisted/renumbered. If a specific ID is permanently unavailable, pick the closest equivalent (search grafana.com for `argocd dashboard` etc.) and update the ID list above + commit message accordingly.

- [ ] **Step 8.11: Munge each downloaded dashboard's datasource UID to `VictoriaMetrics`**

Most grafana.com dashboards use a templated datasource variable (e.g., `${DS_PROMETHEUS}`). Grafana matches that to a datasource by *name* OR by *type*; with `type: prometheus` and only one Prometheus datasource (our `VictoriaMetrics`), the match is automatic. **Manual munge is not strictly required** — but for dashboards with hardcoded UIDs, do this preemptive normalization:

```bash
cd gitops/apps/observability/grafana/dashboards/

for f in *.json; do
  # Replace any literal datasource UID with our datasource name.
  # This is a defensive normalization; many dashboards already use the
  # ${DS_PROMETHEUS}-style template, which works automatically.
  jq '
    walk(if type == "object" and has("datasource") and (.datasource | type) == "object" and .datasource.type == "prometheus"
         then .datasource = {"type": "prometheus", "uid": "VictoriaMetrics"} else . end)
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

cd -
```

Sanity-check one file:

```bash
jq '.panels[0].datasource' gitops/apps/observability/grafana/dashboards/1860-node-exporter-full.json | head -5
# Expect: {"type": "prometheus", "uid": "VictoriaMetrics"}
```

If `walk` isn't available in your `jq` (older versions): `brew upgrade jq` or use `gojq`.

- [ ] **Step 8.12: Write the dashboard ConfigMap templates — one file per dashboard**

Each template is a minimal ConfigMap that loads the corresponding JSON via `.Files.Get`. They all follow the same shape; the per-file pattern is:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-<ID>-<SLUG>
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  <slug>.json: |
{{ .Files.Get "dashboards/<ID>-<SLUG>.json" | indent 4 }}
```

Write all 8:

**`gitops/apps/observability/grafana/templates/dashboards/1860-node-exporter-full.yaml`:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-1860-node-exporter-full
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  node-exporter-full.json: |
{{ .Files.Get "dashboards/1860-node-exporter-full.json" | indent 4 }}
```

**`gitops/apps/observability/grafana/templates/dashboards/13770-kubernetes-views-global.yaml`:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-13770-kubernetes-views-global
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  kubernetes-views-global.json: |
{{ .Files.Get "dashboards/13770-kubernetes-views-global.json" | indent 4 }}
```

**`gitops/apps/observability/grafana/templates/dashboards/13332-kubernetes-views-pods.yaml`:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-13332-kubernetes-views-pods
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  kubernetes-views-pods.json: |
{{ .Files.Get "dashboards/13332-kubernetes-views-pods.json" | indent 4 }}
```

**`gitops/apps/observability/grafana/templates/dashboards/14584-argocd.yaml`:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-14584-argocd
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  argocd.json: |
{{ .Files.Get "dashboards/14584-argocd.json" | indent 4 }}
```

**`gitops/apps/observability/grafana/templates/dashboards/17346-traefik-2.yaml`:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-17346-traefik-2
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  traefik-2.json: |
{{ .Files.Get "dashboards/17346-traefik-2.json" | indent 4 }}
```

**`gitops/apps/observability/grafana/templates/dashboards/20417-cloudnativepg.yaml`:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-20417-cloudnativepg
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  cloudnativepg.json: |
{{ .Files.Get "dashboards/20417-cloudnativepg.json" | indent 4 }}
```

**`gitops/apps/observability/grafana/templates/dashboards/12683-victoriametrics-single.yaml`:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-12683-victoriametrics-single
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  victoriametrics-single.json: |
{{ .Files.Get "dashboards/12683-victoriametrics-single.json" | indent 4 }}
```

**`gitops/apps/observability/grafana/templates/dashboards/12693-vmagent.yaml`:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-12693-vmagent
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  vmagent.json: |
{{ .Files.Get "dashboards/12693-vmagent.json" | indent 4 }}
```

- [ ] **Step 8.13: Helm dependency update**

```bash
helm dependency update gitops/apps/observability/grafana/
ls gitops/apps/observability/grafana/charts/
# Expect: grafana-8.x.x.tgz
```

- [ ] **Step 8.14: Render**

```bash
helm template grafana gitops/apps/observability/grafana/ > /tmp/grafana-render.yaml
wc -l /tmp/grafana-render.yaml
# Expect: ~lots — each dashboard alone is 1-3K JSON lines, so total render is huge (~30-50K lines).
```

If `helm template` errors out with "Files.Get failed" or "file not found", confirm the JSON files are in the right place:

```bash
ls gitops/apps/observability/grafana/dashboards/*.json | wc -l
# Expect: 8
```

- [ ] **Step 8.15: Verify all 9 ConfigMaps render (8 dashboards + 1 datasource)**

```bash
grep -c '^kind: ConfigMap' /tmp/grafana-render.yaml
# Expect: ≥ 9 (8 dashboard CMs + 1 datasource CM + chart-internal CMs).

grep 'grafana_dashboard:' /tmp/grafana-render.yaml | wc -l
# Expect: 8
```

- [ ] **Step 8.16: kubeconform + yamllint**

```bash
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/grafana-render.yaml | tail -3
# Expect: 0 invalid (some "skipped" lines for IngressRoute / ExternalSecret are fine — those CRDs are runtime-validated).

yamllint gitops/apps/observability/grafana/
```

If yamllint complains about line length on dashboard ConfigMaps, that's expected — JSON dashboards are long single lines. Add a `.yamllint` exception or accept the warnings.

- [ ] **Step 8.17: Commit, push, open PR**

```bash
git add gitops/apps/observability/grafana/
git commit -m "$(cat <<'EOF'
feat(observability): Grafana with HTTPS, ESO admin, 8 starter dashboards

Final piece of sub-project #5:

- Grafana chart 8.x deployed in observability tier
- Anonymous read-only + admin from OpenBao via ESO
  (path: secret/grafana/admin; ESO ClusterSecretStore openbao)
- IngressRoute at grafana.frame.chalupatech.com via Traefik
  websecure, default wildcard TLS, external-dns annotation
- VictoriaMetrics datasource auto-provisioned via ConfigMap
  + grafana_datasource: "1" sidecar label
- 8 starter dashboards committed as JSON at chart root and
  rendered as labeled ConfigMaps via .Files.Get + sidecar:
    1860 Node Exporter Full
    13770 Kubernetes Views Global
    13332 Kubernetes Views Pods
    14584 ArgoCD
    17346 Traefik 2
    20417 CloudNativePG
    12683 VictoriaMetrics single
    12693 vmagent
- Grafana self-scrape (serviceMonitor.enabled: true) — vmagent
  picks it up
- 5 Gi local-path PVC for sqlite + provisioning state

Operator runbook completed before this PR (Task 7 of plan):
  - secret/grafana/admin seeded in OpenBao
  - external-secrets policy extended with secret/data/grafana/*

PR 7 of 8 in sub-project #5 (observability).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin feat/gitops-grafana

gh pr create --title "feat(observability): Grafana + 8 starter dashboards (HTTPS, ESO admin)" --body "$(cat <<'EOF'
## Summary
- Grafana chart 8.x in observability tier
- Anonymous read-only + admin from OpenBao via ESO (\`secret/grafana/admin\`)
- IngressRoute at \`https://grafana.frame.chalupatech.com\` (default wildcard TLS, external-dns target annotation)
- VictoriaMetrics datasource auto-provisioned (sidecar)
- 8 starter dashboards committed as JSON, rendered as labeled ConfigMaps
- Grafana self-scrape via ServiceMonitor

## Pre-req: operator runbook (manual, must be done before merge)
- [ ] \`secret/grafana/admin\` seeded in OpenBao with \`admin-user\` + \`admin-password\` fields
- [ ] \`external-secrets\` policy extends \`secret/data/grafana/*\` with \`read\`

## Test plan
- [ ] CI helm template renders cleanly with 9+ ConfigMaps (1 datasource + 8 dashboards)
- [ ] After merge: \`kubectl -n argocd get app grafana\` Synced/Healthy
- [ ] After merge: \`kubectl -n grafana get externalsecret grafana-admin-creds\` SecretSynced=True
- [ ] After merge: \`https://grafana.frame.chalupatech.com\` resolves on LAN, returns HTTP 200
- [ ] After merge: anonymous user lands on Home dashboard
- [ ] After merge: 8 dashboards visible; each renders with VictoriaMetrics datasource (no "datasource not found")
- [ ] After merge: admin login works with credentials from OpenBao
- [ ] After merge: vmagent /targets shows grafana job UP

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 8.18: STOP — wait for user to merge**

- [ ] **Step 8.19: Post-merge verification**

```bash
git checkout main && git pull

kubectl -n argocd get app grafana
# Expect: Synced/Healthy

kubectl -n grafana get externalsecret grafana-admin-creds
# Expect: SecretSynced=True

kubectl -n grafana get secret grafana-admin
# Expect: secret exists

kubectl -n grafana get pods
# Expect: grafana-* 2/2 Running (main container + sidecar)

# DNS resolution on LAN:
nslookup grafana.frame.chalupatech.com 192.168.1.1 | tail -5
# Expect: 192.168.1.230

# HTTPS reachability:
curl -ksSI https://grafana.frame.chalupatech.com/api/health | head -3
# Expect: HTTP/2 200

# Open https://grafana.frame.chalupatech.com in a browser:
# - Anonymous land on Home dashboard.
# - Sidebar → Dashboards → Browse: 8 dashboards listed.
# - Open each dashboard and verify:
#     - No "datasource not found" errors.
#     - Panels render data (may take 1-2 minutes for cAdvisor/kubelet to populate enough series).
# - Sign In → admin / <password from OpenBao> succeeds → admin role.

# Grafana self-scrape:
kubectl -n vm-system port-forward svc/vmagent-vmagent-chalupa 8429:8429 &
PF_PID=$!
sleep 3
curl -s http://localhost:8429/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="grafana") | .health'
# Expect: "up"
kill $PF_PID
```

---

## Task 9: PR 8 — ServiceMonitor toggles on existing platform apps + arrs-pg PodMonitor

Last PR. Enables `serviceMonitor.enabled: true` on existing platform-tier apps (ArgoCD, Traefik, ESO, OpenBao, CNPG operator) and `spec.monitoring.enablePodMonitor: true` on the `arrs-pg` Cluster CRD. Each is a small values.yaml change to an existing app — vmagent picks them up automatically via the prometheus-operator-CRD compat layer.

**Files:**
- Modify: `gitops/apps/platform/argocd/values.yaml`
- Modify: `gitops/apps/platform/traefik/values.yaml`
- Modify: `gitops/apps/platform/external-secrets/values.yaml`
- Modify: `gitops/apps/platform/openbao/values.yaml`
- Modify: `gitops/apps/platform/cnpg-system/values.yaml`
- Modify: `gitops/apps/media/arrs-pg/templates/cluster.yaml`

- [ ] **Step 9.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/serviceMonitor-toggles
```

- [ ] **Step 9.2: ArgoCD — enable ServiceMonitors on all 5 components**

Read the current values.yaml:

```bash
cat gitops/apps/platform/argocd/values.yaml | head -60
```

Locate the `argo-cd:` block (top level under the chart). Add a `metrics` block to each of the 5 components if not present. Find a good anchor like `server:` or `controller:` and insert. Apply:

```yaml
# Add under argo-cd: ... server: section
argo-cd:
  server:
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
        interval: 30s
  repoServer:
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
        interval: 30s
  controller:
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
        interval: 30s
  applicationSet:
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
        interval: 30s
  notifications:
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
        interval: 30s
```

(The exact key names may differ slightly per chart version — verify with `helm show values argo/argo-cd | grep -i serviceMonitor`. The keys above are the typical paths in the upstream chart.)

Render to verify:

```bash
helm dependency update gitops/apps/platform/argocd/ 2>/dev/null || true
helm template argocd gitops/apps/platform/argocd/ | grep -c 'kind: ServiceMonitor'
# Expect: 5 (one per component).
```

- [ ] **Step 9.3: Traefik — enable ServiceMonitor**

Find the metrics block in `gitops/apps/platform/traefik/values.yaml` and add:

```yaml
traefik:
  metrics:
    prometheus:
      enabled: true
      serviceMonitor:
        enabled: true
        namespace: traefik
        interval: 30s
```

Verify:

```bash
helm template traefik gitops/apps/platform/traefik/ | grep -c 'kind: ServiceMonitor'
# Expect: 1
```

- [ ] **Step 9.4: External Secrets Operator — enable ServiceMonitor**

Add to `gitops/apps/platform/external-secrets/values.yaml`:

```yaml
external-secrets:
  serviceMonitor:
    enabled: true
    interval: 30s
```

Verify:

```bash
helm template external-secrets gitops/apps/platform/external-secrets/ | grep -c 'kind: ServiceMonitor'
# Expect: 1
```

- [ ] **Step 9.5: OpenBao — enable telemetry serviceMonitor**

OpenBao's chart exposes telemetry via `serverTelemetry.serviceMonitor.enabled` (mirrors HashiCorp Vault). Add to `gitops/apps/platform/openbao/values.yaml`:

```yaml
openbao:
  serverTelemetry:
    serviceMonitor:
      enabled: true
      interval: 30s
```

Verify (the field key may vary per chart version):

```bash
helm template openbao gitops/apps/platform/openbao/ | grep -c 'kind: ServiceMonitor'
# Expect: 1
```

If the chart's actual key differs, look up the right path with `helm show values openbao/openbao | grep -A2 -i 'serviceMonitor\|telemetry'` and adjust.

- [ ] **Step 9.6: CNPG operator — enable PodMonitor**

CNPG's operator chart uses `monitoring.podMonitorEnabled`. Add to `gitops/apps/platform/cnpg-system/values.yaml`:

```yaml
cloudnative-pg:
  monitoring:
    podMonitorEnabled: true
```

Verify:

```bash
helm template cnpg-system gitops/apps/platform/cnpg-system/ | grep -c 'kind: PodMonitor'
# Expect: ≥ 1
```

- [ ] **Step 9.7: arrs-pg — enable PodMonitor on the Cluster CRD**

Open `gitops/apps/media/arrs-pg/templates/cluster.yaml`. Find the `spec:` section. Add or extend the `monitoring` block:

```yaml
spec:
  # ... existing fields ...
  monitoring:
    enablePodMonitor: true
  # ... rest ...
```

If a `monitoring:` block already exists, just add `enablePodMonitor: true` under it. If not, add the whole block.

Verify by rendering the chart (it's a wrapper, the cluster.yaml is a template):

```bash
helm template arrs-pg gitops/apps/media/arrs-pg/ | grep -A3 'monitoring:' | head -10
# Expect: enablePodMonitor: true
```

(arrs-pg's PodMonitor isn't rendered by the wrapper — it's emitted by the CNPG operator at runtime when it observes `enablePodMonitor: true`. So the verification is "the field is in the rendered Cluster spec.")

- [ ] **Step 9.8: Render all modified charts cleanly**

```bash
for app in argocd traefik external-secrets openbao cnpg-system; do
  echo "=== $app ==="
  helm template $app gitops/apps/platform/$app/ > /tmp/${app}-render.yaml
  kubeconform -strict -ignore-missing-schemas -summary \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    /tmp/${app}-render.yaml | tail -3
done

helm template arrs-pg gitops/apps/media/arrs-pg/ > /tmp/arrs-pg-render.yaml
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  /tmp/arrs-pg-render.yaml | tail -3

# yamllint each modified file:
yamllint \
  gitops/apps/platform/argocd/values.yaml \
  gitops/apps/platform/traefik/values.yaml \
  gitops/apps/platform/external-secrets/values.yaml \
  gitops/apps/platform/openbao/values.yaml \
  gitops/apps/platform/cnpg-system/values.yaml \
  gitops/apps/media/arrs-pg/templates/cluster.yaml
```

- [ ] **Step 9.9: Commit, push, open PR**

```bash
git add \
  gitops/apps/platform/argocd/values.yaml \
  gitops/apps/platform/traefik/values.yaml \
  gitops/apps/platform/external-secrets/values.yaml \
  gitops/apps/platform/openbao/values.yaml \
  gitops/apps/platform/cnpg-system/values.yaml \
  gitops/apps/media/arrs-pg/templates/cluster.yaml

git commit -m "$(cat <<'EOF'
feat(observability): enable ServiceMonitor/PodMonitor on existing apps

Last PR of sub-project #5. Flips the metrics scrape toggles
on apps that already shipped them but had them disabled by
default:

- ArgoCD: 5 ServiceMonitors (server, repo-server, controller,
  applicationset-controller, notifications-controller)
- Traefik: 1 ServiceMonitor
- External Secrets Operator: 1 ServiceMonitor
- OpenBao: 1 ServiceMonitor (telemetry endpoint)
- CNPG operator: 1 PodMonitor (operator pod)
- arrs-pg Cluster CRD: spec.monitoring.enablePodMonitor: true
  (closes the metrics deferral from sub-project #4)

vmagent's selectAllByDefault discovery picks up each new
ServiceMonitor / PodMonitor automatically — no scrape-side
config changes needed. Grafana dashboards (14584 ArgoCD,
20417 CloudNativePG, etc.) start populating.

PR 8 of 8 in sub-project #5 (observability).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin feat/serviceMonitor-toggles

gh pr create --title "feat(observability): ServiceMonitor toggles on platform apps + arrs-pg PodMonitor" --body "$(cat <<'EOF'
## Summary
- ArgoCD: 5 ServiceMonitors (per component)
- Traefik: 1 ServiceMonitor
- ESO: 1 ServiceMonitor
- OpenBao: 1 ServiceMonitor (telemetry)
- CNPG operator: 1 PodMonitor
- arrs-pg Cluster: \`spec.monitoring.enablePodMonitor: true\` (closes #4 deferral)

vmagent auto-discovers each via prometheus-operator-CRDs compat. Grafana dashboards 14584 (ArgoCD) and 20417 (CNPG) begin populating after merge.

## Test plan
- [ ] CI helm template renders cleanly for all 6 modified apps
- [ ] After merge: all 6 Apps still Synced/Healthy
- [ ] vmagent /targets gains 9 new UP entries (5 ArgoCD + Traefik + ESO + OpenBao + CNPG operator + 3 arrs-pg replicas = ~13)
- [ ] Grafana 14584 ArgoCD dashboard populates with sync state
- [ ] Grafana 20417 CNPG dashboard shows arrs-pg with 3 replicas

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 9.10: STOP — wait for user to merge**

- [ ] **Step 9.11: Post-merge verification — full stack walk-through**

```bash
git checkout main && git pull

# All 6 modified apps still Synced/Healthy:
kubectl -n argocd get app argocd traefik external-secrets openbao cnpg-system arrs-pg
# Expect: all rows Synced/Healthy.

# ServiceMonitors and PodMonitors landed:
kubectl get servicemonitor -A | wc -l
# Expect: ≥ 8 (header + 5 ArgoCD + traefik + eso + openbao + grafana + ksm + node-exporter).

kubectl get podmonitor -A | wc -l
# Expect: ≥ 2 (header + cnpg operator + arrs-pg).

# vmagent's /targets — full picture:
kubectl -n vm-system port-forward svc/vmagent-vmagent-chalupa 8429:8429 &
PF_PID=$!
sleep 3

curl -s http://localhost:8429/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.health)"' | sort | uniq -c | sort -rn
# Expect output with all jobs healthy:
#  e.g. 6 cadvisor up
#       6 kubelet up
#       3 node-exporter up
#       3 arrs-pg up                  (NEW)
#       1 kube-state-metrics up
#       1 grafana up
#       1 vmsingle up
#       1 vmagent up
#       1 traefik up                  (NEW)
#       1 external-secrets up         (NEW)
#       1 openbao up                  (NEW)
#       1 cnpg-system up              (NEW)
#       5 argocd-* up                 (NEW)

kill $PF_PID

# Grafana populated: open https://grafana.frame.chalupatech.com
# - Dashboard 14584 (ArgoCD): shows app sync state, repo-server stats, controller stats.
# - Dashboard 20417 (CloudNativePG): shows arrs-pg with 3 replicas, replication lag near 0.
```

- [ ] **Step 9.12: Final end-of-#5 sanity sweep**

```bash
# Cluster footprint of the new stack:
kubectl top pods -A | grep -E '(metrics-server|vm-system|grafana|kube-state-metrics|node-exporter|prometheus-operator-crds)'
# Expect: combined ~ 1 vCPU, ~ 1-1.5 GiB memory.

# 30-day retention is in effect (config wired through):
kubectl -n vm-system port-forward svc/vmsingle-vmsingle-chalupa 8429:8429 &
PF_PID=$!
sleep 2
curl -s http://localhost:8429/-/health
# Expect: OK
curl -s 'http://localhost:8429/api/v1/status/tsdb' | jq '.data | {totalSeries: .totalSeries, headStats: .headStats}'
# Expect: totalSeries > 1000, headStats with numSeries / numLabelPairs / etc.
kill $PF_PID

# argocd-repo-server still under limit:
kubectl -n argocd top pods | grep repo-server
# Expect: usage well under limit.

# All 9 platform apps + 6 media apps + observability tier (6 apps):
kubectl -n argocd get app
# Expect: ~21 apps, all Synced/Healthy.
```

If any check fails, do not declare #5 complete. Investigate; fix in a small follow-up PR if behavior is off.

---

## Self-review checklist

1. **Spec coverage:**
   - Worker disks at 100 GB → done in PR #148 (precursor, merged).
   - `allowVolumeExpansion: true` → Task 1.
   - metrics-server → Task 2.
   - observability ApplicationSet → Task 3.
   - prometheus-operator CRDs → Task 4.
   - VictoriaMetrics topology (vmsingle + vmagent, 40Gi/5Gi PVCs, 30d retention, kubelet/cAdvisor scrapes, self-scrape) → Task 5.
   - kube-state-metrics + node-exporter (workers-only, privileged PSA) → Task 6.
   - OpenBao seed + ESO policy extension → Task 7 (manual operator runbook).
   - Grafana (anonymous-readonly, admin from ESO, IngressRoute, datasource, 8 dashboards) → Task 8.
   - ServiceMonitor toggles + arrs-pg PodMonitor → Task 9.
   - Non-goals (logs, alerting, arr-app exporters, OIDC, vmcluster, NFS) → not addressed (correct — they're explicit non-goals in the spec).

2. **Placeholder scan:** No "TBD"/"TODO"/"add appropriate"/"similar to". Each step shows exact commands or exact YAML. The HEREDOC PR-body templates are intentional — the agent fills them in at runtime.

3. **Type/path consistency:** OpenBao path `secret/grafana/admin` referenced in Task 7 (seed), Task 8 (ESO `remoteRef.key`), and policy `secret/data/grafana/*` in Task 7 — all consistent. K8s Secret name `grafana-admin` referenced in Task 7 (target.name), Task 8 (admin.existingSecret) — consistent. ApplicationSet name `observability-apps` in Task 3 + Task 4/5/6/8 verification — consistent. Sync-wave numbers (-1 namespace, 10 vmsingle, 20 vmagent, 30 scrape CRDs) — internally consistent within Task 5.

4. **Hard gates:** Task 5 includes `argocd-repo-server` memory check post-merge (tied to PR #131 lesson). Task 7 is a hard prerequisite for Task 8 (operator runbook explicitly listed in Task 8's PR description as "must be done before merge"). Each PR-driven task ends with explicit "STOP, wait for user" before its post-merge verification.

5. **STOP points between PRs:** Every PR-driven task (1, 2, 3, 4, 5, 6, 8, 9) has an explicit "STOP — wait for user to merge" step before post-merge verification. Subagents must not stack PRs.

6. **Worktree note:** Plan assumes the executing agent is in an isolated worktree per `superpowers:using-git-worktrees` if the parent invokes that skill before starting.

7. **Memory references checked:**
   - `.helmignore` MUST NOT exclude `charts/` — called out in Tasks 2, 4, 5, 6, 8 (every wrapper that has a chart dependency).
   - external-dns target annotation — mandatory on Grafana IngressRoute (Task 8.8).
   - ESO `external-secrets.io/v1` (NOT v1beta1) — used in Task 8.7.
   - Talos PSA — privileged for node-exporter (Task 6.10), baseline elsewhere.
   - argocd-repo-server memory pressure — verified in Task 5.17, fallback noted.
   - Tailscale macOS Network Extension kubectl interception — pre-flight P-2 fallback to `sudo kubectl`.
   - Cloudflare RFC 1918 filter / Unifi DNS override — referenced in Task 8 verification (LAN-only resolution).
