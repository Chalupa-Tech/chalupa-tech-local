# Observability (Metrics & Visualization) — Design

**Date:** 2026-05-08
**Status:** Approved (pending implementation plan)
**Sub-project:** #5 of a multi-cycle ArgoCD/GitOps rollout. Logging (VictoriaLogs + log shipper) split into a new sub-project #5b. Alerting split into a future sub-project #5c.

## Context

Sub-projects #1–#4 landed the GitOps foundation (ArgoCD, secrets/TLS/Ingress, media stack, CNPG-backed PostgreSQL for the arr stack). Today there is no metrics-server, no log aggregation, and no historical visibility into the cluster: `kubectl top` does not work, there is no record of CPU/RAM/disk trends, and the only way to know a pod is unhappy is to notice the symptom downstream (e.g., Sonarr's `database is locked` exceptions in #4 had no quantitative trend until they became user-visible).

Sub-project #5 closes the metrics/visualization gap end-to-end: a Prometheus-compatible timeseries store, a metrics scraper, exporters for the foundational layer (nodes + Kubernetes object state), and Grafana with HTTPS at `grafana.frame.chalupatech.com` and an opinionated starter dashboard pack. Sub-project #5b will add log aggregation. Sub-project #5c will add alerting.

The cluster gained 3 control-plane nodes plus a 3rd worker over the past two days (HA control plane + capacity), and worker disks were grown 50 GB → 100 GB on 2026-05-08 (PR #148, merged) specifically to give observability PVCs room without crowding kubelet/image-cache headroom.

## Goals

- Deploy `metrics-server` in the platform tier so `kubectl top` and HPA queries against `metrics.k8s.io` work.
- Deploy a new `observability` tier with: Prometheus-Operator CRDs (CRDs only, no controller), VictoriaMetrics operator + a single-node `VMSingle` for storage, a `VMAgent` for scraping, `kube-state-metrics`, `node-exporter`, and Grafana with HTTPS at `grafana.frame.chalupatech.com`.
- Day-1 scrape coverage of the foundational layer: kubelet + cAdvisor (built-in), kube-state-metrics, node-exporter ×3 workers, vmsingle/vmagent self-monitoring, Grafana self-monitoring.
- Day-1 scrape coverage of platform apps that already ship `serviceMonitor.enabled` toggles: ArgoCD (5 components), Traefik, ESO, OpenBao, CNPG operator, and the `arrs-pg` cluster (closes the metrics deferral from sub-project #4).
- Pre-curated 8-dashboard starter pack committed as JSON files, rendered as labeled ConfigMaps; Grafana sidecar auto-loads them. Future dashboards are added by exporting from UI → committing JSON → ArgoCD reconciles.
- All Grafana credentials sourced from OpenBao via ESO, matching the established secret pattern.
- ~~Add `allowVolumeExpansion: true` to the existing `local-path` StorageClass~~ — verified during review of PR #150 (closed) that the upstream chart template `local-path-provisioner-0.0.36/templates/storageclass.yaml` already hardcodes `allowVolumeExpansion: true`. Live cluster confirms the flag is set. No change required; PVC online expansion is already enabled.

## Non-Goals (explicitly out of scope)

- **Log aggregation** — split to **sub-project #5b** (VictoriaLogs + log shipper; design TBD).
- **Alerting** — split to **sub-project #5c**. When it lands, the planned choice is `vmalert` + Alertmanager (same VM ecosystem, declarative `VMRule`/`PrometheusRule` CRDs, richer routing/silence/inhibition primitives than Grafana's built-in alerting). The notification destination (Discord/ntfy/email/Pushover/Telegram) is itself a separate decision in #5c.
- **Application-layer metrics for the arr stack and Tdarr/NzbGet** — these need exporter sidecars (e.g., `onedr0p/exportarr` for arrs) that require API-key wiring per app; deferred to a future small sub-project. Sonarr/Radarr/Seerr/NzbGet/Tdarr will not have Prometheus metrics on day-1.
- **VictoriaMetrics cluster mode (`vmselect`/`vminsert`/`vmstorage`)** — homelab metric volume (~3–5K samples/sec, ~30–50K active series) is 3+ orders of magnitude under what `vmsingle` handles. Decision (a) of brainstorming.
- **OIDC-based Grafana auth** — Grafana uses anonymous-read + admin-from-OpenBao. OIDC via OpenBao OIDC provider is reversible later (values.yaml change); not worth the auth-infrastructure scope today. Decision (e) of brainstorming.
- **Long-term metrics retention beyond 30 days** — physical worker disk is the ceiling (100 GB minus kubelet/image-cache/CNPG/system overhead); 30d at homelab volume occupies ~6 GB. 90d/1y is feasible later via worker disk growth + retention bump; not needed day-1.
- **Per-cluster vmagent dual-write for read-side HA** — single-instance vmagent with a local PVC WAL is sufficient. Decision (a).
- **Mock/synthetic data for testing dashboards** — dashboards are validated against live cluster metrics post-deploy.

## Roadmap (carry forward)

1. **ArgoCD foundation** — DONE 2026-05-04. Spec: `docs/superpowers/specs/2026-05-03-argocd-foundation-design.md`.
2. **Secrets + TLS Ingress** — DONE 2026-05-07. Spec: `docs/superpowers/specs/2026-05-04-secrets-tls-ingress-design.md`.
3. **Media stack** — DONE 2026-05-08. Spec: `docs/superpowers/specs/2026-05-07-media-stack-design.md`.
4. **CloudNativePG + arr-stack PostgreSQL** — DONE 2026-05-08. Spec: `docs/superpowers/specs/2026-05-08-cnpg-arr-postgres-design.md`.
5. **Metrics & Visualization** *(this spec)* — metrics-server + VictoriaMetrics + Grafana + foundational scrape coverage.
5b. **Log aggregation** — VictoriaLogs + log shipper. Builds on #5's Grafana datasource pattern.
5c. **Alerting** — vmalert + Alertmanager + notification destination. Builds on #5's vmsingle datasource and #5/#5b's metric/log corpus.
6. **Home automation** — Home Assistant + Z-Wave in a new privileged LXC.
7. **Backups** — Velero + TrueNAS target. Coordinates with CNPG's WAL archiving.

## Architecture

### Tiering

- **Platform tier addition** — `gitops/apps/platform/metrics-server/` deploys the K8s API extension that serves `metrics.k8s.io`. Consumers are HPA, `kubectl top`, future autoscalers — none of which are observability-stack-specific.
- **New observability tier** — `gitops/apps/observability/` with a new ApplicationSet `gitops/bootstrap/applicationsets/observability.yaml` (clone of `platform.yaml`'s syncPolicy + `ignoreDifferences` block, retargeted at `gitops/apps/observability/*`).
- **One namespace per app**, matching the established `destination.namespace: '{{.path.basename}}'` pattern.

### Repository layout

```
gitops/
├── apps/
│   ├── platform/
│   │   ├── metrics-server/                       NEW
│   │   │   ├── Chart.yaml                        # depends on metrics-server helm chart
│   │   │   ├── Chart.lock
│   │   │   ├── values.yaml
│   │   │   ├── .helmignore
│   │   │   └── templates/
│   │   │       └── namespace.yaml                # baseline PSA
│   │   └── ...existing 9 apps (unchanged)
│   └── observability/                            NEW TIER
│       ├── prometheus-operator-crds/             NEW
│       │   ├── Chart.yaml                        # depends on prometheus-operator-crds chart (CRDs only)
│       │   ├── Chart.lock
│       │   ├── values.yaml
│       │   ├── .helmignore
│       │   └── templates/
│       │       └── namespace.yaml
│       ├── vm-system/                            NEW (vm-operator + VMSingle + VMAgent + scrape config)
│       │   ├── Chart.yaml                        # depends on victoria-metrics-operator helm chart
│       │   ├── Chart.lock
│       │   ├── values.yaml
│       │   ├── .helmignore
│       │   └── templates/
│       │       ├── namespace.yaml                # baseline PSA
│       │       ├── vmsingle.yaml                 # VMSingle CRD (the timeseries store)
│       │       ├── vmagent.yaml                  # VMAgent CRD (the scraper)
│       │       ├── kubelet-vmnodescrape.yaml     # scrapes kubelet /metrics on every node
│       │       └── cadvisor-vmnodescrape.yaml    # scrapes cAdvisor via kubelet on every node
│       ├── kube-state-metrics/                   NEW
│       │   ├── Chart.yaml                        # depends on kube-state-metrics helm chart
│       │   ├── values.yaml                       # serviceMonitor.enabled: true
│       │   ├── .helmignore
│       │   └── templates/
│       │       └── namespace.yaml
│       ├── node-exporter/                        NEW
│       │   ├── Chart.yaml                        # depends on prometheus-node-exporter helm chart
│       │   ├── values.yaml                       # hostNetwork+hostPID, serviceMonitor.enabled, tolerate CP taint? (off — workers only)
│       │   ├── .helmignore
│       │   └── templates/
│       │       └── namespace.yaml                # privileged PSA — node-exporter needs hostPID/hostNetwork
│       └── grafana/                              NEW
│           ├── Chart.yaml                        # depends on grafana helm chart
│           ├── values.yaml                       # IngressRoute, sidecar.dashboards.enabled, anonymous=Viewer, admin.existingSecret
│           ├── .helmignore
│           ├── templates/
│           │   ├── namespace.yaml
│           │   ├── ingressroute.yaml             # https://grafana.frame.chalupatech.com via Traefik
│           │   ├── grafana-admin-externalsecret.yaml
│           │   ├── datasource-vmsingle.yaml      # ConfigMap, label grafana_datasource: "1"
│           │   └── dashboards/                   # rendered: one ConfigMap per JSON, label grafana_dashboard: "1"
│           │       ├── 1860-node-exporter-full.yaml
│           │       ├── 13770-kubernetes-views-global.yaml
│           │       ├── 13332-kubernetes-views-pods.yaml
│           │       ├── 14584-argocd.yaml
│           │       ├── 17346-traefik-2.yaml
│           │       ├── 20417-cloudnativepg.yaml
│           │       ├── 12683-victoriametrics-single.yaml
│           │       └── 12693-vmagent.yaml
│           └── dashboards/                       # raw JSON files at chart root (not in templates/)
│               ├── 1860-node-exporter-full.json  # — read by templates/dashboards/*.yaml via
│               ├── 13770-kubernetes-views-global.json   # `.Files.Get "dashboards/<name>.json"`,
│               ├── ... (8 total, exact IDs/revisions pinned at impl time)   # which is rooted at the
                                                                              # chart directory, not templates/.
├── bootstrap/
│   ├── applicationsets/
│   │   └── observability.yaml                    NEW (clone of platform.yaml retargeted)
│   └── root-app.yaml                             unchanged
└── apps/platform/local-path-provisioner/values.yaml   UNCHANGED — the chart already hardcodes allowVolumeExpansion: true (verified during PR #150 review)
```

### Bootstrap order

Sub-project #5 lands in 8 PRs. Strict order — each builds on the previous. Each merge gates on the deploy.yml `Verify GitOps reconciliation` step, same as #1–#4.

| PR | What | Gate |
|---|---|---|
| 1 | ~~`platform/local-path-provisioner` adds `allowVolumeExpansion: true`~~ — **DROPPED**: chart already hardcodes the flag (PR #150 closed as no-op after review). | n/a — capability already enabled cluster-wide. |
| 2 | `platform/metrics-server`. | `kubectl top nodes` returns data. |
| 3 | `bootstrap/applicationsets/observability.yaml` — empty ApplicationSet (no apps yet — directory glob matches nothing, ApplicationSet generates 0 Applications). | `kubectl -n argocd get appset observability-apps` exists. |
| 4 | `observability/prometheus-operator-crds`. | `kubectl get crd servicemonitors.monitoring.coreos.com` returns OK. |
| 5 | `observability/vm-system` — vm-operator + VMSingle + VMAgent + kubelet/cAdvisor scrapes. | vmsingle pod Running, vmagent pod Running, vmagent's `/api/v1/targets` shows kubelet + cAdvisor scrapes UP. |
| 6 | `observability/kube-state-metrics` + `observability/node-exporter` (one PR — they're foundational and small). | Both apps Synced/Healthy. vmagent shows UP for `kube-state-metrics` and `node-exporter` jobs. |
| 7 | `observability/grafana` — full chart, admin secret + ESO, IngressRoute, datasource ConfigMap, 8 starter dashboards. | `https://grafana.frame.chalupatech.com` resolves over HTTPS, the 8 dashboards are visible, queries return data. |
| 8 | `serviceMonitor.enabled: true` toggles on existing platform apps that ship the option (ArgoCD, Traefik, ESO, OpenBao, CNPG operator) AND `spec.monitoring.enablePodMonitor: true` on the `arrs-pg` Cluster CRD. May land as one PR or split — operator's call. | vmagent's `/api/v1/targets` shows additional jobs UP. The relevant Grafana dashboards (ArgoCD, CNPG) populate. |

PR 1 was dropped (verified no-op). The remaining 7 PRs retain their ordering and dependencies.

### Storage layout (decision c)

| PVC | Size | StorageClass | Backed by | Notes |
|---|---|---|---|---|
| `vmsingle-data` | 40 Gi | `local-path` | one Talos worker | 30 day retention; ~6 GB actual at homelab scale; rest is headroom for cardinality growth (e.g., when arr-app exporters land later) and longer retention if 30d gets bumped. Pinned-to-node by local-path; pod stays Pending if that node down. Acceptable: vmagent buffers on its own PVC during outages. |
| `vmagent-data` | 5 Gi | `local-path` | one Talos worker | WAL buffer for samples queued during vmsingle/network outages. Sized for multi-hour outages without dropping writes. |
| `grafana-data` | 5 Gi | `local-path` | one Talos worker | sqlite + provisioning state (admin user, sessions). Dashboards live in ConfigMaps, not here. Headroom for plugins, image cache, render snapshots if ever enabled. |

All three PVCs use the existing `local-path` StorageClass. The StorageClass already has `allowVolumeExpansion: true` (hardcoded by the upstream chart, verified during PR #150 review), so growing any of these is `kubectl edit pvc` (or values.yaml bump on the relevant CRD); local-path's "expansion" is a metadata-only operation since hostPath has no quotas. Real ceiling is the worker's 100 GB host disk (now grown via PR #148), shared with kubelet image cache, CNPG PG replica, and other local-path tenants on the same worker.

VictoriaMetrics's docs explicitly warn against NFS for the timeseries data path — small random I/O during ingestion + background merges interacts poorly with NFSv4 latency. NFS is not used.

### VictoriaMetrics topology (decision a)

Single-node `VMSingle`. Pinned PostgreSQL-style — one stateful pod, one PVC. No `vmcluster`, no read-side HA pair. `vmagent` is a single Deployment with its own WAL PVC.

```yaml
# Excerpt — vm-system/templates/vmsingle.yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMSingle
metadata:
  name: vmsingle-chalupa
  namespace: vm-system
spec:
  retentionPeriod: "30d"
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
      memory: 1Gi
```

```yaml
# Excerpt — vm-system/templates/vmagent.yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAgent
metadata:
  name: vmagent-chalupa
  namespace: vm-system
spec:
  remoteWrite:
    - url: http://vmsingle-vmsingle-chalupa.vm-system.svc.cluster.local:8429/api/v1/write
  scrapeInterval: 30s
  selectAllByDefault: true   # discovers all VMServiceScrapes/VMPodScrapes/ServiceMonitors/PodMonitors cluster-wide
  serviceScrapeNamespaceSelector: {}
  serviceScrapeSelector: {}
  podScrapeNamespaceSelector: {}
  podScrapeSelector: {}
  resources:
    requests:
      cpu: 100m
      memory: 192Mi
    limits:
      memory: 512Mi
  extraArgs:
    remoteWrite.tmpDataPath: /tmp/vmagent
  storage:
    accessModes: [ReadWriteOnce]
    storageClassName: local-path
    resources:
      requests:
        storage: 5Gi
```

Resource requests/limits are explicitly set per the Talos PSA / OOM-controller lesson: empty `resources: {}` invites the runtime.OOMController to kill the pod under host pressure. Limits are conservative; revisit at impl time after watching steady-state usage in the new dashboards.

### Scrape mechanism (decision b)

vm-operator translates the following CRDs into vmagent scrape config at runtime:

| CRD | Source | Used for |
|---|---|---|
| `VMServiceScrape` | vm-operator | vmsingle/vmagent self-scraping (defined alongside the CRDs in vm-system) |
| `VMPodScrape` | vm-operator | future direct pod scrapes if needed |
| `VMNodeScrape` | vm-operator | kubelet + cAdvisor on every node (built-in `/metrics` endpoints) |
| `VMRule` | vm-operator | (future — alerting in #5c) |
| `ServiceMonitor` | prometheus-operator-crds | upstream chart toggles `serviceMonitor.enabled: true` |
| `PodMonitor` | prometheus-operator-crds | upstream chart toggles `podMonitor.enabled: true` (e.g., CNPG) |
| `PrometheusRule` | prometheus-operator-crds | (future — alerting in #5c) |

`vmagent.spec.selectAllByDefault: true` discovers all of these cluster-wide without explicit selectors. Each `gitops/apps/observability/*` and any platform-app `serviceMonitor.enabled: true` is auto-discovered.

### Day-1 scrape targets (decision i)

| Target | Endpoint | Discovery mechanism |
|---|---|---|
| kubelet | `https://<node>:10250/metrics` | `VMNodeScrape kubelet` in vm-system, with TLS skip + sa token auth |
| cAdvisor | `https://<node>:10250/metrics/cadvisor` | `VMNodeScrape cadvisor` in vm-system, same auth path |
| kube-state-metrics | service in `kube-state-metrics` ns, `/metrics` :8080 | chart's built-in ServiceMonitor (`serviceMonitor.enabled: true`) |
| node-exporter ×3 workers | DaemonSet in `node-exporter` ns, `/metrics` :9100 | chart's built-in ServiceMonitor |
| vmsingle self | service in `vm-system`, `/metrics` :8429 | `VMServiceScrape vmsingle` |
| vmagent self | service in `vm-system`, `/metrics` :8429 | `VMServiceScrape vmagent` |
| Grafana self | service in `grafana`, `/metrics` :3000 | chart's built-in ServiceMonitor (PR 7) |
| ArgoCD ×5 components | services in `argocd` ns, each component's metrics port | toggle `serverMonitor.enabled: true` on the wrapper (PR 8) |
| Traefik | service in `traefik` ns | toggle `metrics.serviceMonitor.enabled: true` (PR 8) |
| ESO | controller service | toggle `serviceMonitor.enabled: true` (PR 8) |
| OpenBao | telemetry endpoint | toggle `serverTelemetry.serviceMonitor.enabled: true` (PR 8) |
| CNPG operator | service in `cnpg-system` | toggle `monitoring.podMonitorEnabled: true` (PR 8) |
| `arrs-pg` Cluster | per-pod metrics endpoint via PostgresExporter sidecar | `spec.monitoring.enablePodMonitor: true` on the Cluster CRD (PR 8) |

node-exporter is **workers-only** — DaemonSet does not tolerate the control-plane `NoSchedule` taint. CPs are kubelet-tainted and run no workloads, so node-level metrics there are not interesting. Adding CP coverage later is a one-line `tolerations:` add.

Media apps (Sonarr, Radarr, Seerr, NzbGet, Tdarr) and Plex are **not** scraped day-1. Defer per non-goals.

### Grafana auth (decision e)

`auth.anonymous.enabled: true` + `auth.anonymous.org_role: Viewer`. Admin password sourced from OpenBao via ESO:

| OpenBao path | Fields | Consumer |
|---|---|---|
| `secret/grafana/admin` | `admin-user` (e.g., `admin`), `admin-password` (32-char random) | Grafana Deployment via `admin.existingSecret: grafana-admin` |

OpenBao policy `grafana-read` (new) grants `read` on `secret/data/grafana/*`, attached to the existing `external-secrets` Vault role.

ExternalSecret `grafana-admin-creds` in the `grafana` namespace produces K8s Secret `grafana-admin` with keys `admin-user`/`admin-password`, referenced by Grafana's chart values.

LAN-only access (Cloudflare RFC 1918 filter blocks external resolution; Unifi wildcard override resolves `*.frame.chalupatech.com` to `192.168.1.230` only on LAN) makes anonymous-readonly an acceptable security posture for a single-user homelab.

### Grafana ingress

```yaml
# Excerpt — grafana/templates/ingressroute.yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
  namespace: grafana
  annotations:
    external-dns.alpha.kubernetes.io/target: "192.168.1.230"
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`grafana.frame.chalupatech.com`)
      kind: Rule
      services:
        - name: grafana
          port: 80
```

The `external-dns.alpha.kubernetes.io/target` annotation is **mandatory** per the established memory pattern — without it, external-dns silently skips the route and the Cloudflare A record never appears (which is fine since Cloudflare's RFC 1918 filter would drop it anyway, but the annotation also drives the local Unifi DNS override path's tracking). Wildcard cert from the existing default Traefik TLSStore (`*.frame.chalupatech.com`) covers the route.

### Grafana datasource provisioning

```yaml
# Excerpt — grafana/templates/datasource-vmsingle.yaml
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
        jsonData:
          httpMethod: POST
          prometheusType: Prometheus
          prometheusVersion: 2.40.0
```

Grafana sidecar (with `sidecar.datasources.enabled: true`) auto-loads this on startup. The datasource is exposed to dashboards as `VictoriaMetrics`.

### Dashboard provisioning (decision f)

8 dashboards committed as raw JSON in `gitops/apps/observability/grafana/dashboards/*.json`. Each rendered as a labeled ConfigMap by `gitops/apps/observability/grafana/templates/dashboards/<id>-<slug>.yaml`:

```yaml
# Excerpt — grafana/templates/dashboards/1860-node-exporter-full.yaml
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

Grafana sidecar's `sidecar.dashboards.enabled: true` watches all ConfigMaps with `grafana_dashboard: "1"` cluster-wide, mounts each into Grafana's provisioning path on the fly. UI-built dashboards remain ephemeral (sqlite-backed); the explicit flow for permanence is "build in UI → export JSON → commit to repo → ArgoCD reconciles → sidecar mounts."

Pinned IDs and revisions chosen at impl time from grafana.com (the IDs above are the targeted starter pack; revision pinning happens on download).

### Network and DNS

| Concern | Resolution |
|---|---|
| `grafana.frame.chalupatech.com` external resolution | Cloudflare RFC 1918 filter drops the A record (192.168.1.230 is private); LAN clients pick up Unifi's wildcard `*.frame.chalupatech.com → 192.168.1.230` override. |
| `grafana.frame.chalupatech.com` LAN access | Unifi DNS override → 192.168.1.230 → Traefik websecure → IngressRoute → grafana service. |
| Wildcard TLS | Default Traefik TLSStore `*.frame.chalupatech.com` (already deployed in #2). |
| `external-dns.alpha.kubernetes.io/target: "192.168.1.230"` annotation | Required on the IngressRoute (per memory). |

### PSA (Pod Security Admission) handling

Per the established Talos PSA pattern, namespaces are labelled in each wrapper's `templates/namespace.yaml`:

| Namespace | PSA level | Why |
|---|---|---|
| `metrics-server` | baseline | runs as non-privileged service account; chart defaults are baseline-compliant |
| `prometheus-operator-crds` | baseline | CRDs only, no workload |
| `vm-system` | baseline | vm-operator, vmsingle, vmagent — none need privileged primitives |
| `kube-state-metrics` | baseline | non-privileged |
| `node-exporter` | **privileged** | DaemonSet uses `hostNetwork: true`, `hostPID: true`, mounts `/proc` and `/sys` for node metrics |
| `grafana` | baseline | non-privileged |

### Resource sizing (Guaranteed QoS for stateful)

All observability components set explicit `resources.requests` and `resources.limits`. Per the established Talos `runtime.OOMController` lesson, anything with stateful PVC or critical scrape state runs Guaranteed QoS (requests==limits) to avoid eviction under host memory pressure:

| Component | requests | limits | QoS |
|---|---|---|---|
| metrics-server | cpu 50m, memory 128Mi | cpu 50m, memory 128Mi | Guaranteed |
| vm-operator | cpu 50m, memory 128Mi | memory 256Mi | Burstable |
| vmsingle | cpu 100m, memory 512Mi | cpu 100m, memory 512Mi | Guaranteed |
| vmagent | cpu 100m, memory 256Mi | cpu 100m, memory 256Mi | Guaranteed |
| kube-state-metrics | cpu 50m, memory 128Mi | memory 256Mi | Burstable |
| node-exporter (DaemonSet) | cpu 50m, memory 64Mi | cpu 50m, memory 64Mi | Guaranteed |
| grafana | cpu 100m, memory 256Mi | memory 512Mi | Burstable |

Probe timeouts are loose (`timeoutSeconds: 5`, not the default `1`) per the lesson about tight probe timeouts crashlooping under load.

Total steady-state additional cluster footprint: **~1.1 vCPU requested, ~1.5 GB requested** across the cluster. Comfortable on the 3×4c/20GB worker pool.

### `argocd-repo-server` render budget

Sub-project #4 hit `argocd-repo-server` OOM during chart render of CNPG (PR #131 raised the memory limit). The observability stack adds 6 wrapper charts that depend on upstream charts — kube-state-metrics, prometheus-node-exporter, victoria-metrics-operator, prometheus-operator-crds, grafana, metrics-server. Each is smaller than CNPG's CRD-heavy chart.

**Mitigation:** post-PR-5 (vm-system, the largest of the new charts) verify `kubectl -n argocd top pods` shows repo-server peak usage well under its limit. If repo-server pressure shows up, raise its memory request similarly to PR #131. Budget the verification as part of PR 5's reconciliation gate.

## Verification (per PR)

Each PR's gate is the deploy.yml `Verify GitOps reconciliation` step plus the named below.

**PR 1 — DROPPED** (chart hardcodes the flag; see Bootstrap order table). Sanity check that the existing cluster state matches what we expect:
```bash
kubectl get sc local-path -o jsonpath='{.allowVolumeExpansion}'
# Expect: true
```

**PR 2 — metrics-server:**
```bash
kubectl top nodes
# Expect: 6 rows with CPU + memory values, no "metrics not available" error.
kubectl top pods -A | head
# Expect: real values.
```

**PR 3 — observability ApplicationSet (empty):**
```bash
kubectl -n argocd get appset observability-apps
# Expect: appset exists, 0 generated apps (empty tier).
```

**PR 4 — prometheus-operator-crds:**
```bash
kubectl get crd servicemonitors.monitoring.coreos.com podmonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com
# Expect: 3 CRDs Established.
```

**PR 5 — vm-system (vmsingle + vmagent + kubelet/cAdvisor scrapes):**
```bash
kubectl -n vm-system get pods
# Expect: vm-operator-* Running, vmsingle-vmsingle-chalupa-0 Running, vmagent-vmagent-chalupa-* Running.

# vmagent UI port-forward:
kubectl -n vm-system port-forward svc/vmagent-vmagent-chalupa 8429:8429
# Visit http://localhost:8429/targets — expect kubelet + cadvisor jobs UP across all 6 nodes.

# vmsingle has data:
curl -s 'http://localhost:8429/api/v1/query?query=up' | jq '.data.result | length'
# Expect: > 10 series.

# argocd-repo-server memory check:
kubectl -n argocd top pods | grep repo-server
# Expect: usage well under limit.
```

**PR 6 — kube-state-metrics + node-exporter:**
```bash
kubectl -n kube-state-metrics get pods
kubectl -n node-exporter get pods   # DaemonSet — 3 pods (one per worker)

# In vmagent /targets: kube-state-metrics + node-exporter jobs UP.
# In vmsingle: queries return data:
#   kube_pod_info{} — Pod inventory
#   node_cpu_seconds_total{} — per-CPU stats
```

**PR 7 — Grafana:**
```bash
# DNS resolves on LAN:
nslookup grafana.frame.chalupatech.com 192.168.1.1
# Expect: 192.168.1.230

# HTTPS works:
curl -ksSI https://grafana.frame.chalupatech.com/login | head -3
# Expect: HTTP/2 200

# Open https://grafana.frame.chalupatech.com in a browser:
# - Anonymous access lands on the Home dashboard.
# - 8 starter dashboards visible in the dashboards list.
# - Each dashboard renders against the VictoriaMetrics datasource (no "datasource not found").
# - Login as admin (creds from OpenBao path secret/grafana/admin) succeeds.

# Grafana ESO sync:
kubectl -n grafana get externalsecret grafana-admin-creds
# Expect: SecretSynced=True

# Grafana self-scrape:
# In vmagent /targets — grafana job UP.
```

**PR 8 — ServiceMonitor toggles on platform apps + arrs-pg PodMonitor:**
```bash
# In vmagent /targets — additional jobs UP for argocd-server, argocd-repo-server,
# argocd-application-controller, argocd-applicationset-controller, traefik,
# external-secrets, openbao, cnpg-controller-manager, arrs-pg.

# Dashboards populate:
# - 14584 ArgoCD shows non-zero apps + sync state.
# - 20417 CloudNativePG shows arrs-pg cluster with 3 replicas, replication lag near 0.
```

**End-of-stack verification (post-PR-8):**
```bash
# 30-day retention is in effect (verifies storage flag wired correctly):
curl -s 'http://localhost:8429/api/v1/status/tsdb' | jq '.data.totalSeries, .data.headStats.numSeries'

# Ingestion rate sanity:
curl -s 'http://localhost:8429/api/v1/query?query=rate(vm_rows_inserted_total[5m])' | jq '.data.result'
# Expect: 1k–10k samples/sec range.

# Grafana sees all expected datasources, dashboards, no provisioning errors:
kubectl -n grafana logs deploy/grafana -c grafana | grep -i 'error\|fail' | grep -v -i 'expected\|harmless' | head
# Expect: no genuine errors.

# Total cluster footprint:
kubectl top pods -A | grep -E '(metrics-server|vm-|grafana|kube-state|node-exporter)'
# Expect: combined ~ 1 vCPU, ~ 1–1.5 Gi memory.
```

## Risks and mitigations

- **vmsingle node pinning.** local-path PVC is bound to one worker. If that worker is down, vmsingle stays Pending and metrics ingestion gaps. **Mitigation:** vmagent has its own PVC WAL — buffers samples through the outage; backfills on reconnect. Worker reboots are typically 1–2 minutes, well within vmagent buffer capacity. Full node loss is rare; recovery via re-provisioning the PVC is acceptable on a homelab.
- **`argocd-repo-server` memory pressure during chart render.** vm-system's chart bundle is non-trivial. **Mitigation:** monitor `kubectl -n argocd top pods` post-PR-5; bump repo-server memory similarly to PR #131 if pressure shows.
- **Dashboard JSON drift between grafana.com revisions and committed copies.** The starter pack is point-in-time. **Mitigation:** that's the entire point of decision (f) — dashboards live in Git, are reviewable in PRs. If a future grafana.com revision adds a panel we want, that's an explicit "download newer JSON, commit, PR-review" workflow, not silent drift.
- **Anonymous Grafana access on LAN.** Anyone on the LAN sees all dashboards. **Mitigation:** acceptable per stated threat model (single-user homelab, LAN-only via Cloudflare RFC 1918 filter + Unifi DNS override). Reversible to OIDC-via-OpenBao later (decision e).
- **node-exporter PSA privileged label.** The `node-exporter` namespace is privileged-PSA. **Mitigation:** documented; the wrapper chart's `templates/namespace.yaml` sets the label explicitly per the established Talos PSA pattern.
- **OpenBao Sealed window after cluster reboot.** Same as #2/#3/#4: operator unseals via `./scripts/openbao/unseal.sh`, ESO resumes, Grafana keeps running on cached K8s Secrets through the unseal window.
- **vmagent missing scrape targets if a chart's `serviceMonitor.enabled` toggle is off.** **Mitigation:** PR 8 explicitly enables them; verification step confirms each shows UP in vmagent's `/targets`.
- **Local-path-provisioner data loss on node reformat.** vmsingle's metrics history would be lost on full node reformat. **Mitigation:** acceptable — metrics aren't data-bearing. Re-scraping populates a fresh 30d window organically. Not worth WAL archiving infrastructure.
- **Dashboard ConfigMap size.** Some dashboards (1860 Node Exporter Full) are ~150 KB JSON. K8s ConfigMap limit is 1 MB; well under. **Mitigation:** none needed at current sizes; if a single dashboard ever exceeded ~800 KB we'd refactor it.
- **Worker disk pressure with VM + CNPG + node-exporter on the same nodes.** All consume local-path. **Mitigation:** PR #148 grew workers to 100 GB. vmsingle on one worker = ~6 GB used + headroom; CNPG replica = ~500 MB to several GB; image cache + ephemeral = the rest. Watch via the new Node Exporter Full dashboard — if any worker hits >80% disk, bump worker disk via Pulumi (the precedent is set in PR #148).
- **VMServiceScrape vs ServiceMonitor selector overlap.** vm-operator with `selectAllByDefault: true` discovers both. If two chart toggles produce both kinds for the same target, vmagent scrapes it twice. **Mitigation:** verify in `/targets` that no job appears doubled; pick one CRD per target if it does.

## Open questions

None blocking. Resolved at implementation time:

- Exact pinned Helm chart versions for: metrics-server, prometheus-operator-crds, victoria-metrics-operator, kube-state-metrics, prometheus-node-exporter, grafana.
- Exact pinned Grafana dashboard revisions for the 8 starter dashboards (download fresh from grafana.com; commit JSON).
- Whether to use `VMServiceScrape`/`VMPodScrape` (vm-operator native) vs. `ServiceMonitor`/`PodMonitor` (prometheus-operator-compat) for vmsingle/vmagent self-scrape — both work; native is one fewer CRD touch.
- Whether node-exporter tolerates the CP `NoSchedule` taint (default: no — workers only). Add CP coverage as a one-line follow-up if needed.
- Final resource limit values for vm-operator, vmsingle, vmagent — start conservative (above), tune after a week of dashboard data.
- Whether PR 8 (ServiceMonitor toggles) lands as one PR or splits per-app — implementation plan's call.

## References

- Sub-project #1 spec: `docs/superpowers/specs/2026-05-03-argocd-foundation-design.md`.
- Sub-project #2 spec: `docs/superpowers/specs/2026-05-04-secrets-tls-ingress-design.md`.
- Sub-project #3 spec: `docs/superpowers/specs/2026-05-07-media-stack-design.md`.
- Sub-project #4 spec: `docs/superpowers/specs/2026-05-08-cnpg-arr-postgres-design.md`.
- Worker disk grow PR: `#148`.
- Project conventions: `CLAUDE.md`.
- Memory: `project_homelab_roadmap.md`, `project_argocd_sync_config.md`, `project_external_dns_target_annotation.md`, `project_talos_psa_constraint.md`, `project_cloudflare_rfc1918_filter.md`.
- VictoriaMetrics: `https://docs.victoriametrics.com/`.
- VictoriaMetrics Operator: `https://docs.victoriametrics.com/operator/`.
- Prometheus Operator CRDs: `https://github.com/prometheus-operator/prometheus-operator`.
- kube-state-metrics: `https://github.com/kubernetes/kube-state-metrics`.
- node-exporter: `https://github.com/prometheus/node_exporter`.
- Grafana provisioning (sidecar pattern): `https://grafana.com/docs/grafana/latest/administration/provisioning/`.
