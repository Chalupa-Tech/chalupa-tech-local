# Log Aggregation (#5b) — Design

**Date:** 2026-05-11
**Status:** Approved (pending implementation plan)
**Sub-project:** #5b of the multi-cycle ArgoCD/GitOps rollout. Split out from sub-project #5 (Metrics & Visualization) during its brainstorming as a separate deliverable to keep #5 focused on metrics.

## Context

Sub-project #5 (DONE 2026-05-10) deployed the metrics + visualization half of cluster observability: kube-state-metrics, node-exporter, kubelet + cAdvisor scrapes, VictoriaMetrics (vmsingle + vmagent), Grafana with HTTPS + ESO admin + 8 starter dashboards. Today the cluster has full metrics coverage, but log analysis still relies on `kubectl logs <pod>` — one-pod-at-a-time, ephemeral (gone when the pod restarts), no cross-pod search, no historical retention.

Sub-project #5b closes the log half: ship every container's stdout/stderr to a VictoriaLogs single-node instance, with retention matching metrics (30 days) and a Grafana datasource via the Loki API compat layer. After #5b, the typical debug workflow becomes "filter by `{namespace="argocd"} | json | level="error"` in Grafana Explore" rather than `kubectl logs argocd-server-... --since=1h | grep error` repeated per pod.

## Roadmap (carry forward)

1. **ArgoCD foundation** — DONE 2026-05-04.
2. **Secrets + TLS Ingress** — DONE 2026-05-07.
3. **Media stack** — DONE 2026-05-08.
4. **CloudNativePG + arr-stack PostgreSQL** — DONE 2026-05-08.
5. **Metrics & Visualization** — DONE 2026-05-10. Spec: `docs/superpowers/specs/2026-05-08-observability-design.md`.
5b. **Log aggregation** *(this spec)* — VictoriaLogs + vector log shipper + Grafana datasource via Loki API compat.
5c. **Alerting** — vmalert + Alertmanager + notification destination. Will operate against both VictoriaMetrics (#5) and VictoriaLogs (#5b) data sources.
6. **Home automation** — Home Assistant + Z-Wave in a new privileged LXC.
7. **Backups** — Velero + TrueNAS target. Coordinates with CNPG's WAL archiving.

## Goals

- Deploy a single-node VictoriaLogs (`vlsingle`) in the existing observability tier, 30-day retention, 30 Gi local-path PVC.
- Deploy `vector` as a DaemonSet on worker nodes (no CP toleration; CPs are tainted and run no app workloads worth logging) that tails container stdout/stderr from `/var/log/pods/` and ships to vlsingle via VictoriaLogs' Loki-compatible push endpoint.
- Vector pipeline includes an auto-JSON-parse step: lines that parse as JSON get their fields merged into the log event (enabling structured queries like `level=error`); non-JSON lines pass through as plaintext.
- Grafana datasource added via the existing `gitops/apps/observability/grafana/` wrapper, using Grafana's built-in Loki datasource pointed at vlsingle. No Grafana plugin install required.
- Pattern consistency with #5: identical wrapper-chart layout (`Chart.yaml` + `values.yaml` + `.helmignore` + `templates/namespace.yaml`), identical sync-wave conventions (`-1` namespace, `0` workload), identical ApplicationSet tier (`observability-apps`).
- Match retention windows: 30 days for logs matches 30 days for metrics so cross-source correlation at the same time range works in Grafana.

## Non-Goals (explicitly out of scope)

- **Talos system logs** (kubelet, etcd, machined, etc.) — Talos doesn't expose journald via traditional Linux paths; the only programmatic source is the Talos HTTPS log API on port 50000 with machine credentials. Building a custom vector source for this is real engineering for marginal payoff at homelab scale. The interactive tool `talosctl logs <node>` covers the 90% case.
- **Kernel/dmesg logs** — same reasoning as Talos system logs.
- **Kubernetes API audit logs** — requires Talos machine-config change to enable audit logging, plus a parser. Compliance/security use case; out of scope for a single-user homelab.
- **App-specific file logs** — none of our apps write logs to files in this cluster; everything uses stdout per Kubernetes best practice. The arr stack writes to files only inside the legacy Plex LXC (not on K8s).
- **Long-term log archive (S3, object storage)** — 30-day local-path retention is adequate; no compliance retention requirement.
- **Log-based alerting** — vmalert can evaluate LogsQL but alerting overall is sub-project #5c, not here.
- **VictoriaLogs cluster mode (`vlinsert`/`vlselect`/`vlstorage`)** — homelab log volume (~350 MB/day uncompressed cluster-wide estimate) is 4+ orders of magnitude under what `vlsingle` handles. Decision (a) of brainstorming.
- **Native LogsQL via the VictoriaLogs Grafana plugin** — Loki API compat covers ~95% of homelab queries (regex, JSON field extraction, label filters, pipe operations). Revisit if/when we need LogsQL-only features like stream joins. Decision (e) of brainstorming.
- **Filebeat / fluent-bit / OpenTelemetry Collector as log shippers** — vector won decision (b). Vector has a native VictoriaLogs sink (no Loki-API translation layer), best K8s metadata enrichment ergonomics, and a clean pipeline-as-code config model.
- **Day-1 dashboards for logs** — beyond the datasource itself, no curated dashboards. Most useful queries are ad-hoc in Grafana Explore. If/when patterns emerge worth dashboarding, ship them in a follow-up small PR.
- **Per-app log volume tuning, exclusion filters, sampling** — ship everything, filter at query time. Disk footprint estimate (~2 GB at 30d retention on a 30 GB PVC) is comfortably under any need to selectively exclude noisy namespaces.

## Architecture

### Tiering

Extends the existing `observability` ApplicationSet (`gitops/bootstrap/applicationsets/observability.yaml`, landed in #5 PR #155). No new tier. Two new wrappers + one modification to the existing `grafana` wrapper.

### Repository layout (additions / modifications)

```
gitops/
└── apps/
    └── observability/
        ├── vl-system/                              NEW
        │   ├── Chart.yaml                          # depends on victoria-logs-single helm chart
        │   ├── Chart.lock
        │   ├── values.yaml                         # 30 Gi local-path PVC, 30d retention, Guaranteed QoS
        │   ├── .helmignore                         # must NOT exclude charts/ (lessons-from-#3)
        │   └── templates/
        │       └── namespace.yaml                  # baseline PSA (vlsingle is a normal stateful service, no host access)
        ├── vector/                                 NEW
        │   ├── Chart.yaml                          # depends on the vector helm chart
        │   ├── Chart.lock
        │   ├── values.yaml                         # DaemonSet workers-only, kubernetes_logs source + remap + loki sink
        │   ├── .helmignore
        │   └── templates/
        │       └── namespace.yaml                  # privileged PSA — vector mounts /var/log/pods host path (like node-exporter)
        └── grafana/
            └── templates/
                └── datasource-vlsingle.yaml        NEW — ConfigMap with grafana_datasource: "1" label, type loki
```

`gitops/bootstrap/applicationsets/observability.yaml` already globs `gitops/apps/observability/*`, so the two new directories auto-generate Applications named `vl-system` and `vector`. The existing `grafana` Application picks up the new datasource template on its next sync.

### Components

| Component | Type | Replicas | Resources (requests = limits) | Storage | QoS |
|---|---|---|---|---|---|
| **vlsingle** (VictoriaLogs single-node) | StatefulSet | 1 | cpu 100m, memory 256Mi | 30 Gi local-path PVC | Guaranteed |
| **vector** (log shipper) | DaemonSet | 1 per worker (3 pods) | cpu 100m, memory 256Mi | EmptyDir for cursor state | Guaranteed |

Total cluster footprint: ~1 GiB RAM (vlsingle + 3× vector), ~30 Gi disk on whichever worker hosts vlsingle's PVC. Sits comfortably alongside #5's existing ~1.5 GiB observability footprint on the 6×(4c/20GB/100Gi) worker pool.

Vector runs **workers-only** by omitting tolerations for the control-plane `NoSchedule` taint, matching the `node-exporter` pattern from #5. CPs are tainted and run no application workloads; capturing their kubelet/api-server logs would require the Talos system-log shipper which is explicitly out of scope.

### Data flow

```
container stdout/stderr
    │
    ▼  kubelet writes to /var/log/pods/<ns>_<pod>_<uid>/<container>/<n>.log
vector DaemonSet (one pod per worker)
    │  source: kubernetes_logs — tails active files; attaches pod/ns/container/node/labels via K8s API
    │  transform: remap (VRL) — tries parse_json(.message); merges fields into the event if it parses; pass-through if not
    │  sink: loki — VL's /loki/api/v1/push (Loki wire protocol)
    ▼
vlsingle StatefulSet (1 replica) at vlsingle-vlsingle-chalupa.vl-system.svc.cluster.local:9428
    │  receives Loki push API
    │  compresses + indexes + stores in 30 Gi local-path PVC
    │  serves /loki/api/v1/{query_range,labels,series} for read path
    ▼
Grafana
    │  built-in "loki" datasource type, no plugin install needed
    │  appears as "VictoriaLogs" in the datasource picker alongside the existing "VictoriaMetrics"
    │  full Logs panel + Explore UI work natively
```

### Vector pipeline (target)

Illustrative values.yaml excerpt; exact field paths get pinned at impl time against the deployed vector chart version.

```yaml
vector:
  role: Agent                       # DaemonSet mode (not Aggregator)

  podSecurityContext:
    fsGroup: 0                      # vector needs to read kubelet-owned log files

  customConfig:
    sources:
      k8s:
        type: kubernetes_logs

    transforms:
      parse_json:
        type: remap
        inputs: [k8s]
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
```

Vector's `kubernetes_logs` source automatically populates `kubernetes.pod_namespace`, `kubernetes.pod_name`, `kubernetes.container_name`, `kubernetes.pod_node_name`, `kubernetes.pod_labels.*`, etc. from the K8s API (requires a ServiceAccount with `get`/`list`/`watch` on pods — vector's chart provides this RBAC out of the box).

JSON parsing logic: if `.message` parses as a JSON object, its fields are merged into the event. Most modern apps (kube-* components, cert-manager, CNPG, ESO, vmagent, Traefik, Grafana itself) emit JSON to stdout, so structured fields like `level`, `time`, `msg`, `http.status_code` become queryable directly in Grafana. Non-JSON apps (most arr apps, OpenBao plaintext audit) fall through with `.message` intact.

### Grafana datasource integration

A single new ConfigMap at `gitops/apps/observability/grafana/templates/datasource-vlsingle.yaml`, mirroring the existing `datasource-vmsingle.yaml`:

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

The Grafana sidecar (`sidecar.datasources.enabled: true`, label `grafana_datasource: "1"` — already configured from #5) auto-mounts this on next reconcile.

After PR 3 merges, you'll see "VictoriaLogs" in Grafana Explore alongside "VictoriaMetrics". Logs panels on dashboards can use either datasource.

### PSA (Pod Security Admission)

| Namespace | PSA level | Why |
|---|---|---|
| `vl-system` | baseline | vlsingle runs as a normal non-privileged service; no host access required |
| `vector` | **privileged** | vector's DaemonSet mounts host paths `/var/log/pods/` (kubelet's log directory; containerd writes to it directly on Talos) to tail container log files. Same pattern as `node-exporter` (#5 Task 6.10). |

### Sync-wave ordering

| Resource | Sync wave |
|---|---|
| `vl-system` namespace | -1 |
| vlsingle helm chart resources (Service, StatefulSet, PVC) | 0 (default) |
| `vector` namespace | -1 |
| vector helm chart resources (DaemonSet, ServiceAccount, ClusterRole, ClusterRoleBinding) | 0 (default) |

No hard ordering across the two wrappers — vector's loki sink retries with backoff if vlsingle's service isn't yet reachable. ArgoCD's `automated.retry.limit: 5` on the observability ApplicationSet handles transient post-merge timing.

### Resource sizing rationale

**vlsingle**: 100m CPU / 256Mi RAM Guaranteed.

- Compression + indexing is CPU-light at homelab volume (~350 MB/day uncompressed → maybe 50 MB/day compressed after VL's encoding pass).
- 256Mi RAM accommodates VL's in-memory write buffer + query result cache.
- Guaranteed QoS prevents Talos's `runtime.OOMController` (now disabled per PR #157 but the convention is durable) from evicting under transient memory pressure on shared workers.
- 30 Gi PVC is ~15× headroom over the steady-state usage estimate (~2 GB at 30d retention).

**vector** (per-pod): 100m CPU / 256Mi RAM Guaranteed.

- 3 pods × 256Mi = ~768Mi cluster-wide.
- CPU usage dominated by `parse_json` per-line attempts. At ~350 MB/day cluster-wide ÷ 3 workers = ~120 MB/day per pod = ~1.4 KB/sec average, ~30 logs/sec. CPU overhead per log line is microseconds; 100m is generous.
- 256Mi RAM accommodates vector's internal buffers + JSON parser allocations.

Probes have `timeoutSeconds: 5` (not the default 1), per the Talos lesson that tight probe timeouts crashloop under load.

## Risks and mitigations

- **vlsingle node pinning.** local-path PVC binds vlsingle to one worker. If that worker is down, vlsingle is `Pending` and ingestion stops. **Mitigation:** vector's loki sink buffers in-memory with on-disk fallback (EmptyDir); samples accumulate during outages and flush on reconnect. Worker reboots are 1–2 minutes — well within vector's buffer capacity. Full worker loss costs all in-flight logs from that window.

- **Vector DaemonSet missing logs during its own pod restart.** If the vector pod on worker-N restarts, container log files on that worker briefly stop being tailed. Vector's cursor state is in EmptyDir (lost on restart), so on next start it begins tailing from the end of the file — losing whatever was written during the gap. **Mitigation:** acceptable at homelab scale; full-fidelity log capture would require a persistent cursor file via PVC, which is per-pod-per-worker overhead that doesn't pay back. If we ever care about not-missing-a-line, swap EmptyDir for a tiny local-path PVC per pod.

- **Vector requires `privileged` PSA on the vector namespace.** Documented; the wrapper's `templates/namespace.yaml` sets it explicitly. Same pattern as node-exporter (#5).

- **JSON parsing overhead on every log line.** Vector's `parse_json` tries to parse every `.message`. For non-JSON apps this is a wasted attempt per line. **Mitigation:** parse_json is a fast Rust path; overhead is sub-microsecond per line. At homelab volume the cost is invisible.

- **Stream label cardinality blowup.** The four labels (namespace, pod, container, node) are bounded by cluster object counts. Total streams: ~30 pods × ~3 containers each × maybe 20 unique label-combos = ~few hundred streams. Loki/VL handle thousands of streams trivially. Not a real concern at this scale.

- **Grafana Loki datasource limits.** Grafana's Loki query UI has built-in row caps (5000 rows by default). For homelab debugging this is plenty; explicitly worth knowing if you ever need to export a large window.

- **vlsingle StatefulSet PVC retention on chart change.** If we ever bump the vlsingle Helm chart in a way that renames the StatefulSet's `volumeClaimTemplates`, the existing PVC may not be reattached. **Mitigation:** pin a specific chart minor version in `Chart.yaml`; verify post-merge that the PVC re-attaches by name. The 30-day log history is recoverable-from-scratch (just re-scrape), so this is a low-stakes risk.

- **Vector chart configuration drift across versions.** The vector helm chart's `customConfig` schema is stable, but other keys (e.g., `podMonitor.enabled`, `dataDir`) have churned across versions. **Mitigation:** apply the same lesson as #5 — `helm show values vector/vector --version <pin>` at impl time, then build the values.yaml against the chart's actual schema.

- **`.helmignore` accidentally excluding `charts/`.** Repeated lesson from #3. The skeleton in PR templates includes the standard 6 lines without `charts/`.

- **Workers-only DaemonSet leaves CP container logs un-captured.** This is the design choice — CPs are tainted, run no application workloads. The CP containers we *do* care about (apiserver, scheduler, controller-manager) live in `kube-system` namespace and run as static pods scheduled to CPs by Talos. Their stdout *is* written to `/var/log/pods/` on the CP nodes, but our vector DaemonSet doesn't tolerate the taint so it never lands there. **Mitigation:** documented; if a CP-side debug story emerges, we can add `tolerations:` to vector's values.yaml in a one-line follow-up.

## Verification (per PR)

**PR 1 — vl-system:**
```bash
kubectl -n vl-system get pods
# Expect: vlsingle-vlsingle-chalupa-0  1/1  Running

kubectl -n vl-system get pvc
# Expect: 30 Gi PVC Bound

kubectl -n vl-system port-forward svc/vlsingle-vlsingle-chalupa 9428:9428 &
PF=$!
sleep 2
curl -s http://localhost:9428/health
# Expect: OK
curl -s http://localhost:9428/metrics | head
# Expect: prometheus-format VL metrics
kill $PF
```

**PR 2 — vector:**
```bash
kubectl -n vector get pods -o wide
# Expect: 3 pods Running, one on each worker (.226 .227 .232), zero on CPs

kubectl -n vector logs ds/vector --tail=20 | grep -i 'sink.*loki\|connected\|fail'
# Expect: lines indicating vector started, attached to /var/log/pods, connected to vlsingle
# No "connection refused" or repeated retries.

# vector's internal metrics expose target count + events processed:
kubectl -n vector port-forward svc/vector 8686:8686 &
PF=$!
sleep 2
curl -s http://localhost:8686/metrics | grep -E 'vector_(events_in_total|component_received|component_sent)'
# Expect: counters incrementing
kill $PF
```

**PR 3 — Grafana datasource ConfigMap:**
```bash
kubectl -n grafana get configmap grafana-datasource-vlsingle
# Expect: present

kubectl -n grafana logs deploy/grafana -c grafana-sc-datasources --tail=20 | grep -i 'vlsingle\|victorialogs'
# Expect: sidecar detected + applied the new ConfigMap

# Open https://grafana.frame.chalupatech.com:
# - Explore → datasource picker → "VictoriaLogs" appears alongside "VictoriaMetrics"
# - Query: {namespace="argocd"} (LogQL stream selector)
#   → returns a stream of ArgoCD pod logs
# - Query: {namespace="argocd"} | json | level="error"
#   → returns only error-level events from apps that emit JSON
# - Query: {namespace="media", container="sonarr"}
#   → returns Sonarr logs (plaintext, since arr apps don't emit JSON)
```

**End-of-stack verification (after PR 3 merges):**
```bash
# Ingestion is keeping up — vlsingle's ingestion rate should match vector's emission rate:
kubectl -n vl-system port-forward svc/vlsingle-vlsingle-chalupa 9428:9428 &
PF=$!
sleep 2
curl -s 'http://localhost:9428/select/logsql/query?query=*&limit=1' | head
# Expect: at least 1 log entry returned, with kubernetes_pod_name field etc.

# Disk usage in line with expectations:
curl -s 'http://localhost:9428/metrics' | grep -E 'vl_storage_bytes_used|vl_compressed_bytes'
# Expect: bytes_used grows over time at roughly 50-100 MB/day after a 24h soak

kill $PF
```

## Implementation note: isolated git worktree

Implementation MUST happen in an isolated git worktree to keep #5b's branches/refs cleanly separated from the user's other in-flight work (the existing `.claude/worktrees/observability-impl` worktree was used for #5 and should not be reused for #5b). Use `superpowers:using-git-worktrees` (via `EnterWorktree` native tool) to create a fresh worktree at `.claude/worktrees/log-aggregation-impl` (or auto-generated name) before starting Task 1. The worktree branch will be ahead of `origin/main` by however many PRs are in flight; each PR task does its own `git fetch origin main && git reset --hard origin/main && git checkout -b feat/...` to start from a clean base.

## Lessons applied from #5

- **Verify post-merge on the data plane, not just ArgoCD's view.** For vlsingle and vector specifically, the post-merge checklist runs `curl` against the actual service endpoints and `kubectl logs` against the actual pods, not just `kubectl -n argocd get app`. ArgoCD's `Synced/Healthy` only verifies that resources matching the manifest were created; it doesn't see operator-translation failures or runtime crash loops downstream.
- **Wrapper `appVersion` matches dep chart's actual `appVersion`.** Run `helm show chart <repo>/<chart> --version <pinned>` at impl time and pin the wrapper's appVersion to match (Task 4 lesson from #5).
- **Confirm helm chart key paths against the actual schema.** Run `helm show values <repo>/<chart> --version <pinned>` to see what keys the chart accepts before writing values.yaml (Tasks 6 + 9 lessons from #5).
- **Probe registry before pinning image tags.** Don't infer image tags from release notes or convention — verify with `docker manifest inspect` or registry HTTP HEAD (per the `feedback_verify_image_tag_on_registry.md` memory entry).
- **`.helmignore` MUST NOT exclude `charts/`** (lessons-from-#3 memory entry — applies to every wrapper).

## Open questions (resolved at implementation time)

- Exact pinned chart versions for `victoria-logs-single` and `vector` (use latest stable within the major series available at impl time).
- Exact field path for vector's `kubernetes_logs` source vs the chart's `customConfig` (`helm show values vector/vector --version <pin>` confirms the wrapping).
- Vector chart repo URL — the canonical chart is at `https://helm.vector.dev`; if a different community fork is preferred at impl time we use that.
- VictoriaLogs chart repo URL — the canonical chart is `victoria-logs-single` from `https://victoriametrics.github.io/helm-charts/` (same repo as the vm-operator and vmsingle charts we already use).
- Whether to disable vlsingle's built-in scrape target via `serviceMonitor.enabled: false` initially (defer self-monitoring until #5c brings alerting, or wire it day-1 alongside vmagent's existing self-scrape pattern).

## References

- Sub-project #5 spec: `docs/superpowers/specs/2026-05-08-observability-design.md`.
- Sub-project #5 plan: `docs/superpowers/plans/2026-05-08-observability-plan.md`.
- VictoriaLogs docs: `https://docs.victoriametrics.com/victorialogs/`.
- VictoriaLogs Loki API compatibility: `https://docs.victoriametrics.com/victorialogs/data-ingestion/loki/`.
- Vector docs: `https://vector.dev/docs/`.
- Vector `kubernetes_logs` source: `https://vector.dev/docs/reference/configuration/sources/kubernetes_logs/`.
- Vector `loki` sink: `https://vector.dev/docs/reference/configuration/sinks/loki/`.
- Project conventions: `CLAUDE.md`.
- Memory: `project_homelab_roadmap.md`, `project_argocd_sync_config.md`, `project_talos_psa_constraint.md`, `feedback_verify_image_tag_on_registry.md`.
