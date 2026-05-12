# Log Aggregation (#5b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship every Kubernetes container's stdout/stderr to a VictoriaLogs single-node instance via a vector DaemonSet, and expose it as a Grafana datasource using the Loki API compatibility layer — yielding cross-pod, 30-day-retention log search in Grafana Explore without any plugin install or Talos system-log shipper.

**Architecture:** Two new Helm wrappers in the existing `observability` ApplicationSet tier (vl-system, vector) plus one ConfigMap modification to the existing grafana wrapper. vlsingle is a StatefulSet (1 replica, 30 Gi local-path PVC, 30d retention). Vector is a workers-only DaemonSet that tails `/var/log/pods/`, runs a `remap` transform that auto-parses JSON-when-detected, and ships via Loki push protocol. Grafana's built-in Loki datasource type connects to vlsingle — no plugin install.

**Tech Stack:** Helm 3, kubeconform, ArgoCD ApplicationSet (`observability-apps`), External Secrets Operator 2.4.x (not used here directly — vector has no secrets), VictoriaLogs 1.x (`victoria-logs-single` Helm chart from https://victoriametrics.github.io/helm-charts/), vector 0.40+ (`vector` Helm chart from https://helm.vector.dev). Pinned chart versions in this plan are the targeted starting point as of 2026-05-11; bump within the same major at impl time if newer is stable on `helm search repo --versions`.

**Reference spec:** `docs/superpowers/specs/2026-05-11-log-aggregation-design.md`.

**Branching strategy:** One feature branch per task, one PR per task, one merge to `main`. All 3 tasks are PR-driven (no manual operator runbook).

**Pre-existing prerequisites (already satisfied):**

- Sub-project #5 fully merged: vmsingle + vmagent + grafana + kube-state-metrics + node-exporter + prometheus-operator-crds + metrics-server.
- `observability-apps` ApplicationSet exists at `gitops/bootstrap/applicationsets/observability.yaml` and globs `gitops/apps/observability/*` — picks up new directories automatically.
- Grafana has the sidecar enabled (`sidecar.datasources.enabled: true`, label `grafana_datasource: "1"`) — the new datasource ConfigMap is automatically loaded.
- `local-path` StorageClass exists with `allowVolumeExpansion: true` (verified live; chart hardcodes it).
- 6 Talos nodes Ready: 3 CPs (.225, .228, .229) at 2c/6GB/50GB, 3 workers (.226, .227, .232) at 4c/20GB/100GB.
- Default Traefik TLSStore wildcard cert covers `*.frame.chalupatech.com` (not used here — no new IngressRoutes).

---

## Pre-Flight

### Step P-0: Set up an isolated worktree for #5b

This is REQUIRED. The existing `.claude/worktrees/observability-impl` was used for #5; do NOT reuse it. Create a fresh worktree.

If you are the parent agent invoking this plan: use the `EnterWorktree` native tool (per `superpowers:using-git-worktrees`):

```
EnterWorktree(name: "log-aggregation-impl")
```

This creates `.claude/worktrees/log-aggregation-impl/` on a fresh `worktree-log-aggregation-impl` branch based at the current `HEAD` (which should be at or near `origin/main`).

If the harness lacks `EnterWorktree`, fall back to manual:

```bash
cd /Users/tbigelow/Documents/code/chalupa-tech-local
git fetch origin main
git worktree add -b worktree-log-aggregation-impl .claude/worktrees/log-aggregation-impl origin/main
cd .claude/worktrees/log-aggregation-impl
```

Verify you are in the new worktree:

```bash
pwd
# Expect: ends in /.claude/worktrees/log-aggregation-impl
GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
[ "$GIT_DIR" != "$GIT_COMMON" ] && echo "OK: in linked worktree" || echo "FAIL: in primary worktree"
```

**All subsequent steps run from this worktree.**

### Step P-1: Verify local CLIs

```bash
helm version --short                    # expect: v3.x
kubeconform -v                          # expect: v0.6+
yamllint --version                      # expect: any
gh --version                            # expect: gh version 2.x
jq --version                            # expect: jq-1.6+
kubectl version --client                # expect: v1.30+ (Homebrew-signed)
curl --version | head -1
```

If any are missing: `brew install <tool>`. kubectl must be the Homebrew-signed binary (per `project_tailscale_kubectl_ehostunreach` memory).

### Step P-2: Set KUBECONFIG

```bash
cd /Users/tbigelow/Documents/code/chalupa-tech-local/pulumi-talos
pulumi stack output kubeconfig --show-secrets > ~/.kube/chalupa-cluster.yaml
cd - >/dev/null
chmod 600 ~/.kube/chalupa-cluster.yaml
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
kubectl get nodes
```

Expect: 6 nodes Ready. If `no route to host`, switch to `sudo kubectl ...` for everything (Tailscale macOS Network Extension interception).

### Step P-3: Sanity-check sub-project #5 is still healthy

```bash
kubectl -n argocd get app vm-system grafana kube-state-metrics node-exporter prometheus-operator-crds metrics-server -o wide
# Expect: all rows Synced/Healthy

kubectl -n vm-system get pods
# Expect: vm-operator + vmsingle + vmagent all Running

kubectl -n grafana get pods
# Expect: grafana pod Running 3/3
```

If any check fails, STOP — fix #5's state before adding #5b on top.

### Step P-4: Add the vector + victoriametrics helm repos

```bash
helm repo add vm https://victoriametrics.github.io/helm-charts/ 2>/dev/null || true
helm repo add vector https://helm.vector.dev 2>/dev/null || true
helm repo update vm vector

# Confirm the charts we'll consume are visible:
helm search repo vm/victoria-logs-single --versions | head -5
helm search repo vector/vector --versions | head -5
```

Each should print at least one recent version. **Record the latest stable version of each** for use in Task 1 / Task 2 (Chart.yaml pinning).

### Step P-5: Probe image tags exist on registry (per memory)

The helm charts pull container images by version. Don't trust the chart's defaults blindly — probe the registry directly. After you pin chart versions in Task 1 / Task 2, run `helm show values <repo>/<chart> --version <pinned>` to learn the default image tag, then verify it exists on the registry:

```bash
# Example for VictoriaLogs (replace <tag> with what the chart defaults to):
docker manifest inspect victoriametrics/victoria-logs:<tag> >/dev/null 2>&1 && echo "OK: tag exists" || echo "MISSING: tag not on registry"

# Example for vector:
docker manifest inspect timberio/vector:<tag>-distroless-static >/dev/null 2>&1 && echo "OK" || echo "MISSING"
```

If a tag is missing, the helm chart will deploy but the pod will `ImagePullBackOff` indefinitely. Fix by either upgrading the chart pin to a version whose default image tag exists, or overriding `image.tag` in values.yaml.

---

## Task 1: PR 1 — `observability/vl-system`

Deploys VictoriaLogs single-node (`vlsingle`) via the official Helm chart, with 30 Gi local-path PVC, 30-day retention, Guaranteed QoS, baseline PSA. Sets up the receiver for vector's log shipping in Task 2.

**Files:**
- Create: `gitops/apps/observability/vl-system/Chart.yaml`
- Create: `gitops/apps/observability/vl-system/Chart.lock`
- Create: `gitops/apps/observability/vl-system/values.yaml`
- Create: `gitops/apps/observability/vl-system/.helmignore`
- Create: `gitops/apps/observability/vl-system/templates/namespace.yaml`

### Task 1.1: Create branch

```bash
cd /Users/tbigelow/Documents/code/chalupa-tech-local/.claude/worktrees/log-aggregation-impl
pwd   # confirm worktree

git fetch origin main
git reset --hard origin/main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] && echo "OK: HEAD==origin/main" || echo "MISMATCH — STOP"

git checkout -b feat/gitops-vl-system
```

If the HEAD-vs-origin/main check fails, STOP and report BLOCKED.

### Task 1.2: Create directory structure

```bash
mkdir -p gitops/apps/observability/vl-system/templates
```

### Task 1.3: Confirm latest 0.x version of victoria-logs-single chart + its actual appVersion

```bash
helm search repo vm/victoria-logs-single --versions | head -5
```

Note the latest stable version (likely 0.x.x at impl time). Then:

```bash
helm show chart vm/victoria-logs-single --version <chosen-version> | grep -E '^(version|appVersion):'
```

Record both numbers. The wrapper's `appVersion` MUST match the dep chart's actual appVersion (Task 4 lesson from #5).

### Task 1.4: Write `gitops/apps/observability/vl-system/Chart.yaml`

Replace `<CHART_VERSION>` and `<APP_VERSION>` with the values from Step 1.3.

```yaml
apiVersion: v2
name: vl-system-wrapper
description: VictoriaLogs single-node (vlsingle) — 30 Gi local-path PVC, 30d retention, Loki-compatible ingest + query
type: application
version: 0.1.0
appVersion: "<APP_VERSION>"
dependencies:
  - name: victoria-logs-single
    version: <CHART_VERSION>
    repository: https://victoriametrics.github.io/helm-charts/
```

### Task 1.5: Write `gitops/apps/observability/vl-system/.helmignore`

```
.git/
.gitignore
.DS_Store
*.swp
*.swo
*~
```

Do NOT include `charts/` — that's the vendored dep dir (lessons-from-#3 memory).

### Task 1.6: Inspect the chart's values schema before writing values.yaml

The exact field paths for retention, storage, and resources may differ slightly per chart version. Confirm before writing:

```bash
helm show values vm/victoria-logs-single --version <chosen-version> > /tmp/vls-defaults.yaml
grep -nE '^(retentionPeriod|retention|persistentVolume|resources|service|fullnameOverride|nameOverride)' /tmp/vls-defaults.yaml | head -30
grep -nE 'storage|persistent|claim' /tmp/vls-defaults.yaml | head -20
```

Use the actual key paths the chart exposes. The keys below match the v0.x chart family as of writing; verify before applying.

### Task 1.7: Write `gitops/apps/observability/vl-system/values.yaml`

```yaml
victoria-logs-single:
  server:
    # 30-day retention (matches metrics retention from #5 — cross-source
    # correlation in Grafana works at the same time range).
    retentionPeriod: "30d"

    replicaCount: 1

    persistentVolume:
      enabled: true
      storageClassName: local-path
      size: 30Gi
      accessModes:
        - ReadWriteOnce

    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 100m
        memory: 256Mi   # Guaranteed QoS — small foundational service

    # Loose probe timeouts per Talos lesson (tight timeoutSeconds: 1 crashloops
    # under transient load on shared workers).
    probe:
      liveness:
        timeoutSeconds: 5
        periodSeconds: 30
      readiness:
        timeoutSeconds: 5
        periodSeconds: 10

    # Self-scrape via the existing vm-system VMAgent's selectAllByDefault: true
    # (a ServiceMonitor produced by this chart will be auto-discovered).
    serviceMonitor:
      enabled: true
      interval: 30s
```

If the chart at the pinned version uses different key paths (e.g., `persistence.*` instead of `persistentVolume.*`), adjust to match.

### Task 1.8: Write `gitops/apps/observability/vl-system/templates/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vl-system
  labels:
    # baseline PSA: vlsingle runs as a normal non-privileged service; no host
    # access required.
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

### Task 1.9: Helm dependency update

```bash
helm dependency update gitops/apps/observability/vl-system/
ls gitops/apps/observability/vl-system/charts/
# Expect: victoria-logs-single-<version>.tgz

test -f gitops/apps/observability/vl-system/Chart.lock && echo "Chart.lock generated"
```

### Task 1.10: Probe image tag exists on registry

```bash
# Get the default image tag the chart wants to pull:
helm show values vm/victoria-logs-single --version <chosen-version> | grep -A1 'server:' | grep -A1 'image:' | grep 'tag:'

# Then verify the tag exists (replace <tag> with what the previous command returned):
docker manifest inspect victoriametrics/victoria-logs:<tag> >/dev/null 2>&1 && echo "OK: image tag exists" || echo "MISSING: image tag not on registry — bump chart or override image.tag"
```

If MISSING, override `server.image.tag` in values.yaml to a known-good tag from `docker run victoriametrics/victoria-logs:latest --version` or by checking the registry index.

### Task 1.11: Render + validate

```bash
helm template vl-system gitops/apps/observability/vl-system/ > /tmp/vls-render.yaml
wc -l /tmp/vls-render.yaml
# Expect: ~300-600 lines (small chart)

kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/vls-render.yaml | tail -3
# Expect: 0 invalid

# Confirm expected resources:
grep -c '^kind: StatefulSet' /tmp/vls-render.yaml    # Expect: 1
grep -c '^kind: Service' /tmp/vls-render.yaml         # Expect: ≥ 1 (headless + clusterIP)
grep -c '^kind: ServiceMonitor' /tmp/vls-render.yaml  # Expect: 1 (if serviceMonitor.enabled wired correctly)

# yamllint:
yamllint gitops/apps/observability/vl-system/
```

If `ServiceMonitor` count is 0, the chart's serviceMonitor key path differs from `victoria-logs-single.server.serviceMonitor` — re-inspect `helm show values` and adjust values.yaml.

### Task 1.12: Commit, push, open PR

```bash
git status -s
# Expect: only files under gitops/apps/observability/vl-system/

git add gitops/apps/observability/vl-system/Chart.yaml \
        gitops/apps/observability/vl-system/Chart.lock \
        gitops/apps/observability/vl-system/values.yaml \
        gitops/apps/observability/vl-system/.helmignore \
        gitops/apps/observability/vl-system/templates/namespace.yaml

git diff --cached --stat
# Expect: 5 files

git commit -m "$(cat <<'EOF'
feat(observability): VictoriaLogs single-node (vlsingle)

Deploys VictoriaLogs as a wrapper chart in the observability tier:
- victoria-logs-single chart <version> (appVersion <app-version>)
- vlsingle StatefulSet, 1 replica, 30 Gi local-path PVC, 30d retention
- Guaranteed QoS (100m CPU / 256Mi RAM), loose probe timeouts
- ServiceMonitor enabled — auto-picked up by vm-system's VMAgent
  (selectAllByDefault: true from #5 PR #158)
- baseline PSA — vlsingle is a normal non-privileged service

Task 1 of 3 in sub-project #5b (log aggregation).
Spec: docs/superpowers/specs/2026-05-11-log-aggregation-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin feat/gitops-vl-system

gh pr create --title "feat(observability): VictoriaLogs single-node (vlsingle)" --body "$(cat <<'EOF'
## Summary
- New observability-tier app: `gitops/apps/observability/vl-system/`
- victoria-logs-single chart <version> — VictoriaLogs <app-version>
- vlsingle StatefulSet, 1 replica, 30 Gi local-path PVC, 30d retention
- Guaranteed QoS
- ServiceMonitor enabled — auto-discovered by VMAgent's selectAllByDefault

## Pre-req for downstream (Task 2)
After this merges, vector (Task 2) ships logs to `http://vlsingle-vlsingle-chalupa.vl-system.svc.cluster.local:9428/loki/api/v1/push`.

## Test plan (DATA-PLANE — not just ArgoCD status, per #5 lesson)
- [ ] CI helm template renders cleanly
- [ ] After merge: `kubectl -n argocd get app vl-system` Synced/Healthy
- [ ] After merge: `kubectl -n vl-system get pods` shows `vlsingle-vlsingle-chalupa-0  1/1  Running` (NOT just "Application Synced")
- [ ] After merge: `kubectl -n vl-system get pvc` shows a Bound PVC of 30 Gi
- [ ] After merge: port-forward and curl the `/health` endpoint returns `OK`
- [ ] After merge: vmagent's `/api/v1/targets` shows `vlsingle` job in `up` state

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### Task 1.13: STOP — wait for user to merge

Surface the PR URL. Do not run post-merge verification until the user confirms merge.

### Task 1.14: Post-merge DATA-PLANE verification (run on cluster, not just ArgoCD)

```bash
git checkout main && git pull
# Wait ~30s for ArgoCD to reconcile + StatefulSet to come up:
sleep 30

# 1. ArgoCD app status:
kubectl -n argocd get app vl-system
# Expect: Synced/Healthy

# 2. Pod is actually running (data plane!):
kubectl -n vl-system get pods
# Expect: vlsingle-vlsingle-chalupa-0  1/1  Running, restart count 0

# If the pod is not Running, STOP — investigate (kubectl describe pod, kubectl logs).
# Do NOT assume ArgoCD's "Synced/Healthy" means the workload works (the #5 vm-agent
# disaster was exactly this — ArgoCD Synced/Healthy with vmagent CRD's status: failed).

# 3. PVC bound:
kubectl -n vl-system get pvc
# Expect: PVC Bound, capacity 30 Gi

# 4. /health endpoint reachable:
kubectl -n vl-system port-forward svc/vlsingle-vlsingle-chalupa 9428:9428 >/dev/null 2>&1 &
PF=$!
sleep 3
curl -s http://localhost:9428/health
# Expect: OK (or 200-equivalent)

# 5. /metrics endpoint reachable:
curl -s http://localhost:9428/metrics | head -5
# Expect: prometheus-format VictoriaLogs metrics

# 6. Loki API endpoints exist:
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9428/loki/api/v1/labels
# Expect: 200 (empty labels response, since no logs ingested yet)

kill $PF 2>/dev/null

# 7. ServiceMonitor auto-discovered:
kubectl -n vm-system port-forward svc/vmagent-vmagent-chalupa 8429:8429 >/dev/null 2>&1 &
PF=$!
sleep 3
curl -s http://localhost:8429/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job | test("vlsingle|vl-system")) | "\(.labels.job)\t\(.health)"' | head
# Expect: at least 1 row, health=up

kill $PF 2>/dev/null
```

All 7 checks should pass. If any fails, do NOT proceed to Task 2 — investigate first.

---

## Task 2: PR 2 — `observability/vector`

Deploys vector as a DaemonSet on workers, tails `/var/log/pods/`, parses JSON-when-detected, ships to vlsingle via Loki push API.

**Files:**
- Create: `gitops/apps/observability/vector/Chart.yaml`
- Create: `gitops/apps/observability/vector/Chart.lock`
- Create: `gitops/apps/observability/vector/values.yaml`
- Create: `gitops/apps/observability/vector/.helmignore`
- Create: `gitops/apps/observability/vector/templates/namespace.yaml`

### Task 2.1: Create branch

```bash
cd /Users/tbigelow/Documents/code/chalupa-tech-local/.claude/worktrees/log-aggregation-impl

git fetch origin main
git reset --hard origin/main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] && echo "OK" || echo "MISMATCH — STOP"

git checkout -b feat/gitops-vector
```

### Task 2.2: Create directory structure

```bash
mkdir -p gitops/apps/observability/vector/templates
```

### Task 2.3: Confirm latest vector chart version + actual appVersion

```bash
helm search repo vector/vector --versions | head -5
helm show chart vector/vector --version <chosen-version> | grep -E '^(version|appVersion):'
```

### Task 2.4: Write `gitops/apps/observability/vector/Chart.yaml`

```yaml
apiVersion: v2
name: vector-wrapper
description: Vector log shipper — workers-only DaemonSet that tails container stdout/stderr and ships to vlsingle via Loki API
type: application
version: 0.1.0
appVersion: "<APP_VERSION>"
dependencies:
  - name: vector
    version: <CHART_VERSION>
    repository: https://helm.vector.dev
```

### Task 2.5: Write `gitops/apps/observability/vector/.helmignore`

```
.git/
.gitignore
.DS_Store
*.swp
*.swo
*~
```

### Task 2.6: Inspect the chart's values schema

```bash
helm show values vector/vector --version <chosen-version> > /tmp/vector-defaults.yaml
grep -nE '^(role|customConfig|podMonitor|serviceMonitor|tolerations|resources|nodeSelector|securityContext|extraVolumeMounts|hostPath)' /tmp/vector-defaults.yaml | head -30
```

Use the actual key paths the chart exposes.

### Task 2.7: Write `gitops/apps/observability/vector/values.yaml`

```yaml
vector:
  # DaemonSet mode (one pod per node) — not Aggregator (StatefulSet).
  role: Agent

  # Workers-only — do NOT tolerate the control-plane NoSchedule taint. CPs
  # run no application workloads worth logging, and capturing kube-system
  # static-pod logs there would require Talos system-log shipping which is
  # explicitly out of scope (see spec non-goals).
  tolerations: []

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 100m
      memory: 256Mi   # Guaranteed QoS

  # vector's customConfig REPLACES the chart's default config. We define the
  # full pipeline here for clarity.
  customConfig:
    data_dir: /vector-data-dir

    api:
      enabled: true
      address: 0.0.0.0:8686

    sources:
      k8s:
        type: kubernetes_logs

    transforms:
      parse_json:
        type: remap
        inputs: [k8s]
        # Try to parse .message as JSON. If it succeeds AND yields an object,
        # merge the parsed fields into the event (so .level, .time, .msg etc.
        # become queryable). If parsing fails, leave the event unchanged.
        source: |
          structured, err = parse_json(.message)
          if err == null && is_object(structured) {
            . = merge(., structured)
          }

    sinks:
      vl:
        type: loki
        inputs: [parse_json]
        endpoint: http://vlsingle-vlsingle-chalupa.vl-system.svc.cluster.local:9428
        labels:
          namespace: '{{ kubernetes.pod_namespace }}'
          pod: '{{ kubernetes.pod_name }}'
          container: '{{ kubernetes.container_name }}'
          node: '{{ kubernetes.pod_node_name }}'
        encoding:
          codec: json
        compression: snappy
        out_of_order_action: accept

  # ServiceMonitor / PodMonitor — auto-discovered by vm-agent.
  serviceMonitor:
    enabled: true
    interval: 30s
```

If the chart at the pinned version uses different keys (e.g., `customConfig` is under a different path, or `tolerations: []` doesn't actually clear chart defaults), adjust to match. Vector chart sometimes ships with chart-default tolerations that explicitly DO tolerate the CP taint — verify with `helm template` after writing values.yaml that the rendered DaemonSet has NO `tolerations` block (or has only ones that don't match CP).

### Task 2.8: Write `gitops/apps/observability/vector/templates/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vector
  labels:
    # Privileged PSA — vector mounts /var/log/pods (host path) to tail
    # container log files. Same pattern as node-exporter (#5 Task 6).
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

### Task 2.9: Helm dependency update

```bash
helm dependency update gitops/apps/observability/vector/
ls gitops/apps/observability/vector/charts/
# Expect: vector-<version>.tgz
test -f gitops/apps/observability/vector/Chart.lock && echo "Chart.lock generated"
```

### Task 2.10: Probe image tag exists on registry

```bash
helm show values vector/vector --version <chosen-version> | grep -A2 '^image:' | head
# Note the default repository + tag
docker manifest inspect timberio/vector:<tag> >/dev/null 2>&1 && echo "OK" || echo "MISSING"
```

### Task 2.11: Render + validate, including tolerations check

```bash
helm template vector gitops/apps/observability/vector/ > /tmp/vector-render.yaml
wc -l /tmp/vector-render.yaml

kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/vector-render.yaml | tail -3
# Expect: 0 invalid

# DaemonSet structure:
grep -c '^kind: DaemonSet' /tmp/vector-render.yaml         # Expect: 1
grep -c '^kind: ServiceMonitor' /tmp/vector-render.yaml    # Expect: 1
grep -c '^kind: ServiceAccount' /tmp/vector-render.yaml    # Expect: 1
grep -c '^kind: ClusterRole' /tmp/vector-render.yaml       # Expect: 1
grep -c '^kind: ClusterRoleBinding' /tmp/vector-render.yaml # Expect: 1

# CRITICAL: confirm DaemonSet has no toleration for CP NoSchedule taint:
sed -n '/^kind: DaemonSet/,/^---/p' /tmp/vector-render.yaml | grep -A5 'tolerations:' | head -10
# Expect: empty (tolerations: []) OR only tolerations for node.kubernetes.io/* (NOT node-role.kubernetes.io/control-plane).
# If you see `- key: node-role.kubernetes.io/control-plane` — the values.yaml override didn't take effect.
# STOP and fix before merging — otherwise vector lands on CPs.

# yamllint:
yamllint gitops/apps/observability/vector/
```

### Task 2.12: Commit, push, open PR

```bash
git status -s
# Expect: only files under gitops/apps/observability/vector/

git add gitops/apps/observability/vector/Chart.yaml \
        gitops/apps/observability/vector/Chart.lock \
        gitops/apps/observability/vector/values.yaml \
        gitops/apps/observability/vector/.helmignore \
        gitops/apps/observability/vector/templates/namespace.yaml

git diff --cached --stat
# Expect: 5 files

git commit -m "$(cat <<'EOF'
feat(observability): vector log shipper (DaemonSet, workers-only)

Deploys vector as a DaemonSet in the observability tier:
- vector chart <version> (appVersion <app-version>)
- Workers-only (tolerations: [] overrides chart default to exclude CPs)
- customConfig: kubernetes_logs source → remap (auto-parse JSON) →
  loki sink to vlsingle (Loki API compat from Task 1)
- Privileged PSA — mounts host /var/log/pods to tail container logs
- ServiceMonitor enabled — auto-discovered by VMAgent for self-monitoring

Vector's remap transform tries parse_json on every log line's .message
field; if it succeeds AND yields an object, the structured fields are
merged into the event (so `level=error`, `http.status_code=500`, etc.
become queryable in Grafana). Non-JSON apps fall through unchanged.

Task 2 of 3 in sub-project #5b (log aggregation).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin feat/gitops-vector

gh pr create --title "feat(observability): vector log shipper (DaemonSet, workers-only)" --body "$(cat <<'EOF'
## Summary
- New observability-tier app: `gitops/apps/observability/vector/`
- vector chart <version> — DaemonSet
- `customConfig`: kubernetes_logs → remap (parse JSON when detected) → loki sink to vlsingle
- Workers-only (`tolerations: []` overrides chart default)
- Privileged PSA (vector mounts `/var/log/pods` host path)
- ServiceMonitor enabled — auto-discovered by VMAgent

## Pre-req
- Task 1 (vl-system) MUST be merged + verified before this merges. Vector ships to `http://vlsingle-vlsingle-chalupa.vl-system.svc.cluster.local:9428` and will retry-with-backoff until vlsingle is reachable.

## Test plan (DATA-PLANE — not just ArgoCD status)
- [ ] CI helm template renders cleanly
- [ ] Rendered DaemonSet has NO toleration for CP NoSchedule (workers-only enforced)
- [ ] After merge: `kubectl -n argocd get app vector` Synced/Healthy
- [ ] After merge: `kubectl -n vector get pods -o wide` shows exactly 3 pods Running, one on each worker IP (.226 .227 .232), NONE on CP IPs (.225 .228 .229)
- [ ] After merge: `kubectl -n vector logs ds/vector --tail=30` shows vector started, found `/var/log/pods/`, connected to vlsingle's Loki endpoint with no repeated retry errors
- [ ] After merge: vector's /metrics endpoint shows non-zero `vector_events_in_total{component_id="k8s"}` and `vector_component_sent_events_total{component_id="vl"}`
- [ ] After merge: vlsingle's /loki/api/v1/labels returns non-empty (logs are being received)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### Task 2.13: STOP — wait for user to merge

### Task 2.14: Post-merge DATA-PLANE verification

```bash
git checkout main && git pull
sleep 30

# 1. App synced:
kubectl -n argocd get app vector
# Expect: Synced/Healthy

# 2. THREE pods, all Running, all on workers (DATA-PLANE — verify pod placement):
kubectl -n vector get pods -o wide
# Expect: exactly 3 pods Running.
# Node column for each pod should be a worker (.226 / .227 / .232), NOT a CP.

# CRITICAL: if you see 6 pods (one per node), the tolerations: [] didn't take effect
# and vector landed on CPs. STOP — re-investigate the chart's tolerations key path.

# 3. Vector started cleanly:
kubectl -n vector logs ds/vector --tail=50 | grep -iE 'error|panic|fail' | head
# Expect: empty (no errors). Or only benign warnings.

# 4. Vector reports its sink as connected:
kubectl -n vector logs ds/vector --tail=100 | grep -iE 'sink.*loki|connected to|started' | head
# Expect: lines indicating successful connection to vlsingle.

# 5. Vector is processing events:
POD=$(kubectl -n vector get pods -o jsonpath='{.items[0].metadata.name}')
kubectl -n vector port-forward "pod/$POD" 8686:8686 >/dev/null 2>&1 &
PF=$!
sleep 3
curl -s http://localhost:8686/metrics | grep -E 'vector_(component_received_events_total|component_sent_events_total)' | grep -E 'k8s|vl' | head
# Expect: non-zero counts, increasing over time.
kill $PF 2>/dev/null

# 6. vlsingle is receiving logs:
kubectl -n vl-system port-forward svc/vlsingle-vlsingle-chalupa 9428:9428 >/dev/null 2>&1 &
PF=$!
sleep 3
curl -s http://localhost:9428/loki/api/v1/labels | jq '.data | length'
# Expect: >= 4 (at least namespace, pod, container, node labels populated)

curl -s -G 'http://localhost:9428/loki/api/v1/query_range' \
  --data-urlencode 'query={namespace="kube-system"}' \
  --data-urlencode 'limit=1' | jq '.data.result | length'
# Expect: > 0 (at least 1 stream of logs from kube-system)
kill $PF 2>/dev/null
```

All 6 checks should pass. If pods land on CPs (check 2), or vlsingle's labels endpoint returns empty (check 6), STOP — do not proceed.

---

## Task 3: PR 3 — Grafana datasource ConfigMap

Single-file addition to the existing `observability/grafana` wrapper: a new ConfigMap with `grafana_datasource: "1"` label that the Grafana sidecar auto-loads on its next reconcile, exposing `VictoriaLogs` as a Loki-typed datasource in the Grafana UI.

**Files:**
- Create: `gitops/apps/observability/grafana/templates/datasource-vlsingle.yaml`

### Task 3.1: Create branch

```bash
cd /Users/tbigelow/Documents/code/chalupa-tech-local/.claude/worktrees/log-aggregation-impl

git fetch origin main
git reset --hard origin/main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] && echo "OK" || echo "MISMATCH — STOP"

git checkout -b feat/grafana-datasource-vlsingle
```

### Task 3.2: Inspect existing datasource template for the pattern

```bash
cat gitops/apps/observability/grafana/templates/datasource-vmsingle.yaml
```

This is the prior-art pattern. The new file mirrors its shape exactly with vlsingle endpoint + Loki type.

### Task 3.3: Write `gitops/apps/observability/grafana/templates/datasource-vlsingle.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-vlsingle
  namespace: grafana
  labels:
    grafana_datasource: "1"
data:
  vlsingle.yaml: |
    apiVersion: 1
    datasources:
      - name: VictoriaLogs
        type: loki
        access: proxy
        url: http://vlsingle-vlsingle-chalupa.vl-system.svc.cluster.local:9428
        isDefault: false
        editable: false
```

### Task 3.4: Render + validate

```bash
helm dependency update gitops/apps/observability/grafana/ 2>&1 | tail -2

helm template grafana gitops/apps/observability/grafana/ > /tmp/grafana-render.yaml
echo "ConfigMaps with grafana_datasource label:"
grep -B1 'grafana_datasource: "1"' /tmp/grafana-render.yaml | grep 'name:' | head
# Expect: TWO names — grafana-datasource-vmsingle (from #5) AND grafana-datasource-vlsingle (new)

kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  /tmp/grafana-render.yaml | tail -3
# Expect: 0 invalid

yamllint gitops/apps/observability/grafana/
```

### Task 3.5: Commit, push, open PR

```bash
git status -s
# Expect: only the one new file

git add gitops/apps/observability/grafana/templates/datasource-vlsingle.yaml
git diff --cached --stat
# Expect: 1 file added

git commit -m "$(cat <<'EOF'
feat(grafana): VictoriaLogs datasource via Loki API compat

Adds a ConfigMap with grafana_datasource: "1" label that the Grafana
sidecar auto-loads. Exposes VictoriaLogs as a Loki-typed datasource
named "VictoriaLogs" in the Grafana UI, pointing at vlsingle's Loki-
compatible /loki/api/v1/* endpoint.

After this lands, Grafana Explore shows "VictoriaLogs" alongside the
existing "VictoriaMetrics" datasource. LogQL queries work natively
(e.g., {namespace="argocd"} | json | level="error"). No Grafana plugin
install required — type: loki uses Grafana's built-in Loki datasource.

Task 3 of 3 in sub-project #5b (log aggregation). Final task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin feat/grafana-datasource-vlsingle

gh pr create --title "feat(grafana): VictoriaLogs datasource via Loki API compat" --body "$(cat <<'EOF'
## Summary
- One new ConfigMap: `gitops/apps/observability/grafana/templates/datasource-vlsingle.yaml`
- Exposes "VictoriaLogs" as a Loki-typed datasource in Grafana
- Sidecar (`sidecar.datasources.enabled: true` from #5) auto-loads on next reconcile
- No Grafana plugin install needed

## Pre-req
- Task 1 (vl-system) + Task 2 (vector) MUST be merged + verified first. Without them, the datasource will appear in Grafana but queries return empty (no log data yet).

## Test plan (DATA-PLANE)
- [ ] CI helm template renders cleanly with both VictoriaMetrics + VictoriaLogs ConfigMaps
- [ ] After merge: `kubectl -n argocd get app grafana` Synced/Healthy
- [ ] After merge: `kubectl -n grafana get configmap grafana-datasource-vlsingle` exists
- [ ] After merge: open https://grafana.frame.chalupatech.com → Explore → datasource picker shows "VictoriaLogs"
- [ ] After merge: in Explore on VictoriaLogs, query `{namespace="argocd"}` returns rows
- [ ] After merge: structured query `{namespace="argocd"} | json | level="error"` works (returns rows from JSON-emitting apps)
- [ ] After merge: substring query `{namespace="media"} |~ "(?i)error"` works

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### Task 3.6: STOP — wait for user to merge

### Task 3.7: Post-merge DATA-PLANE verification

```bash
git checkout main && git pull
sleep 30

# 1. App synced:
kubectl -n argocd get app grafana
# Expect: Synced/Healthy

# 2. ConfigMap present:
kubectl -n grafana get configmap grafana-datasource-vlsingle
# Expect: configmap exists

# 3. Sidecar picked it up:
kubectl -n grafana logs deploy/grafana -c grafana-sc-datasources --tail=30 | grep -i 'vlsingle\|victorialogs\|added' | tail
# Expect: line(s) confirming the sidecar loaded the new datasource

# 4. Grafana UI — manual check (open browser):
echo "Open https://grafana.frame.chalupatech.com"
echo "Explore → datasource picker → 'VictoriaLogs' should appear"
echo ""
echo "Try these queries:"
echo '  {namespace="argocd"}'
echo '  {namespace="argocd"} | json | level="error"'
echo '  {namespace="kube-system",container="kube-apiserver"} | json'
echo '  {namespace="media", container="sonarr"}'
echo '  {namespace="vl-system"}              # vlsingle scraping its own logs back'
```

End-of-sub-project sanity sweep (after Task 3 merges + verifies):

```bash
# All 3 new #5b apps Synced/Healthy:
kubectl -n argocd get app vl-system vector grafana
# Expect: all Synced/Healthy

# Vector is ingesting at expected rate (~30 logs/sec per pod is normal):
POD=$(kubectl -n vector get pods -o jsonpath='{.items[0].metadata.name}')
kubectl -n vector port-forward "pod/$POD" 8686:8686 >/dev/null 2>&1 &
PF=$!
sleep 3
curl -s http://localhost:8686/metrics | grep 'vector_component_sent_events_total{component_id="vl"' | head
kill $PF 2>/dev/null

# vlsingle disk usage growing as expected (~50-100 MB/day after a 24h soak):
kubectl -n vl-system port-forward svc/vlsingle-vlsingle-chalupa 9428:9428 >/dev/null 2>&1 &
PF=$!
sleep 3
curl -s http://localhost:9428/metrics | grep -E 'vl_storage_data_bytes|vl_storage_logs_total' | head
kill $PF 2>/dev/null

# Cluster footprint:
kubectl top pods -n vl-system -n vector 2>&1 | head -10
# Expect: vlsingle ~50-100 MiB RAM, vector pods ~30-100 MiB each
```

---

## Self-review checklist

1. **Spec coverage:**
   - vlsingle (single-node VictoriaLogs, 30 Gi local-path, 30d retention) → Task 1.
   - vector DaemonSet workers-only, kubernetes_logs + parse_json + loki sink → Task 2.
   - Loki API compat datasource in Grafana via ConfigMap + sidecar → Task 3.
   - Privileged PSA on vector namespace → Task 2.8.
   - baseline PSA on vl-system namespace → Task 1.8.
   - ServiceMonitor on both vlsingle and vector → vlsingle in Task 1.7, vector in Task 2.7.
   - Non-goals (Talos system logs, kernel, audit, S3 archive, alerting, vlcluster, native LogsQL plugin) → not addressed (correct — they're explicit non-goals in the spec).

2. **Placeholder scan:** Required values like `<CHART_VERSION>`, `<APP_VERSION>`, `<tag>` are intentional placeholders that the implementer fills in at impl time after running `helm search repo --versions` + `helm show chart`. These are NOT plan failures — they correctly defer impl-time decisions to the human/agent who has access to the live registries. Every other step shows exact code or exact commands.

3. **Type / path consistency:**
   - Service URL `http://vlsingle-vlsingle-chalupa.vl-system.svc.cluster.local:9428` referenced in Task 2.7 (vector's loki sink) and Task 3.3 (grafana datasource) — identical. Used identically in spec.
   - Namespace names: `vl-system` (Task 1.8 + Task 3.3 reference URL), `vector` (Task 2.8) — consistent.
   - Wrapper chart names: `vl-system-wrapper` (Task 1.4), `vector-wrapper` (Task 2.4) — match the established `*-wrapper` convention.
   - Sync waves: `-1` namespace, `0` workload — same as #5.

4. **Hard gates:**
   - Task 1 has a CRITICAL check on data-plane verification (Task 1.14) — the #5 vmagent lesson applied.
   - Task 2 has a CRITICAL check on tolerations (Task 2.11): rendered DaemonSet MUST NOT have a CP toleration. If it does, the values.yaml override didn't take effect — STOP before merging.
   - Task 2 has a CRITICAL check post-merge (Task 2.14): exactly 3 vector pods on workers only — STOP if 6 pods (CPs got included).
   - Each PR-driven task ends with explicit "STOP, wait for user to merge" before data-plane verification.

5. **STOP points between PRs:** Every task (1, 2, 3) has an explicit STOP step. Subagents must not stack PRs.

6. **Worktree note:** Plan opens with Step P-0 explicitly requiring a fresh worktree via `superpowers:using-git-worktrees` (`EnterWorktree(name: "log-aggregation-impl")`). The #5 worktree (`.claude/worktrees/observability-impl`) is NOT reused.

7. **Lessons-from-#5 baked in:**
   - Data-plane verification (not just ArgoCD's `Synced/Healthy`) in every post-merge check.
   - Wrapper appVersion matches dep chart's actual appVersion → Task 1.3 + Task 2.3.
   - `helm show values` per chart at impl time → Task 1.6 + Task 2.6.
   - Probe image tag exists on registry before pinning → Task 1.10 + Task 2.10 + Step P-5.
   - `.helmignore` MUST NOT exclude `charts/` → called out in Task 1.5 + Task 2.5.
   - Talos PSA — privileged for vector (host-path mount), baseline elsewhere → Task 1.8 + Task 2.8.
   - Talos lessons (loose probe timeouts, Guaranteed QoS for stateful) → Task 1.7.
