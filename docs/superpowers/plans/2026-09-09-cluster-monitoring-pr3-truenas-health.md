# Cluster Monitoring PR 3 — TrueNAS Health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface TrueNAS's own health/SMART alert list as a Prometheus metric (`truenas_alert_active{level, klass}`) via json_exporter, and alert on it through the existing vmalert → Alertmanager → HA → Discord pipeline.

**Architecture:** A new GitOps app `gitops/apps/observability/truenas-alerts` (local wrapper chart around bjw-s app-template, like `truenas-exporter`) deploys prometheus-community json_exporter, which probes `https://192.168.1.40/api/v2.0/alert/list` with a bearer-token API key delivered OpenBao → ExternalSecret → Secret → file mount. A VMServiceScrape makes vmagent scrape the probe endpoint; a new `truenas.yaml` VMRule in the **vmalert** app (vm-system namespace) turns the metric into Discord alerts. No vmagent/vmalert/CI-workflow changes are needed (`selectAllByDefault: true` everywhere; `VMServiceScrape` already in kubeconform SKIP_KINDS).

**Tech Stack:** Helm (templates-only + app-template 5.1.0 dependency), VictoriaMetrics operator CRDs (VMServiceScrape, VMRule), External Secrets Operator v1, OpenBao KV v2, json_exporter v0.8.0.

**Design spec:** `docs/superpowers/specs/2026-09-08-cluster-monitoring-design.md` (Components §4, "Initial rule set" truenas.yaml rows, Secrets table row 3).

## Deviations from the spec (verified live 2026-09-09 — do not "fix" these back)

1. **TrueNASDiskTempHigh is dropped.** The spec assumed `disk_temperature{job="truenas"}` exists. Live VictoriaMetrics query (30-day range) shows it has **never** existed — the netdata→graphite path only ships `cpu_temperature`, `disk_busy`, `disk_io`, `disk_io_ops`, etc. Disk-overheat coverage instead comes through `truenas_alert_active` (TrueNAS's smartd raises temperature alerts once thresholds are set — RUNBOOK documents that optional UI step). Restoring disk temp *metrics* is a truenas-exporter/netdata follow-up, recorded in the docs entry.
2. **TrueNASMetricsStale uses `absent()`, not the spec's `timestamp()` expression.** `(time() - max(timestamp(cpu_temperature{job="truenas"}))) > 300` can never fire: once the last sample is older than the instant-query lookbehind (~5m), the inner vector is empty and the whole expression returns no data. `absent(cpu_temperature{job="truenas"})` fires at the same staleness point, latches until data returns, and matches the repo's established absent-guard pattern.
3. **Two severity tiers via level matchers:** TrueNAS levels are `INFO NOTICE WARNING ERROR CRITICAL ALERT EMERGENCY`. CRITICAL-and-above (`CRITICAL|ALERT|EMERGENCY`) → severity critical; everything else → warning (handoff said "CRITICAL → critical"; ALERT/EMERGENCY rank *above* CRITICAL in TrueNAS's enum, so they're included).

## Global Constraints

- All changes via PR — never push to `main`; no local `kubectl apply` of GitOps state (ephemeral e2e test objects applied+deleted by hand are the one sanctioned exception).
- PR 3 touches only `gitops/`, `scripts/openbao/policies/`, and `docs/` — NOT `pulumi/` (TrueNAS VM is protected).
- Commits: conventional style, each ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Image tag `v0.8.0` for `quay.io/prometheuscommunity/json-exporter` was verified against the quay.io tags API on 2026-09-09 (newest release; also tagged `latest`/`v0`, pushed 2026-08-13). Do not substitute another tag without re-probing the registry.
- Helm-escape all Prometheus templating in VMRule annotations: `{{ "{{ $labels.klass }}" }}` renders to literal `{{ $labels.klass }}`. Bare `{{ $labels... }}` breaks the required render check.
- vm-operator CRDs are schemaless in CI (kubeconform skips them) — field-name typos surface only at apply time via the operator's admission webhook, and one rejected resource blocks the whole app's sync. Endpoint-level scrape field is `interval`, NOT `scrapeInterval`.
- yamllint config is `extends: relaxed` + `line-length: disable`; it runs on **raw templates**, so keep any Helm directives inside quoted YAML scalars (this plan's templates need none outside the rules file).
- `gitops/apps/*/*/charts/` tarballs are gitignored; `Chart.lock` IS committed.
- **OpenBao must be seeded BEFORE the PR merges** (ExternalSecret that can't resolve → app Degraded → retry budget (~20 min) exhausts and never restarts; recovery: `kubectl -n argocd annotate application truenas-alerts argocd.argoproj.io/refresh=hard --overwrite`).
- Verification loop per task: `helm template <name> <dir>` + `yamllint gitops/` green before commit.
- Track progress in `.superpowers/sdd/progress.md` in this worktree.

---

### Task 1: truenas-alerts chart scaffold (Chart.yaml, values.yaml, namespace)

**Files:**
- Create: `gitops/apps/observability/truenas-alerts/Chart.yaml`
- Create: `gitops/apps/observability/truenas-alerts/values.yaml`
- Create: `gitops/apps/observability/truenas-alerts/templates/namespace.yaml`
- Create (generated): `gitops/apps/observability/truenas-alerts/Chart.lock`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: an app-template release named `truenas-alerts` whose single Service is named `truenas-alerts` with label `app.kubernetes.io/name: truenas-alerts`, port name `http` → 7979 (Task 3's VMServiceScrape selector and Task 4's `job="truenas-alerts"` matcher depend on these names). Deployment mounts expect ConfigMap `truenas-alerts-config` (Task 2) and Secret `truenas-alerts-api-key` (Task 2's ExternalSecret target).

- [ ] **Step 1: Write `gitops/apps/observability/truenas-alerts/Chart.yaml`**

```yaml
apiVersion: v2
name: truenas-alerts
description: |
  TrueNAS health/SMART alert mirror for VictoriaMetrics.

  TrueNAS already runs scheduled SMART tests and watches pool health;
  its alert list is the single source of truth for everything the NAS
  detects (the HBA is passed through to the VM, so only TrueNAS can see
  the disks). json_exporter polls the REST API:

    vmagent ──scrape /probe──▶ json_exporter ──GET──▶ https://192.168.1.40
                                                       /api/v2.0/alert/list

  and exposes truenas_alert_active{level, klass} — one series per
  active (undismissed) TrueNAS alert. The truenas.yaml VMRule in the
  vmalert app turns those into Discord notifications.

  Auth: TrueNAS API key as a bearer token, OpenBao → ExternalSecret →
  Secret → file mount (never in Git). See RUNBOOK.md for the one-time
  API-key + seeding steps. The image tag is pinned; verify against
  quay.io tags API before bumping.
type: application
version: 0.1.0
appVersion: "v0.8.0"
dependencies:
  - name: app-template
    version: 5.1.0
    repository: https://bjw-s-labs.github.io/helm-charts/
```

- [ ] **Step 2: Write `gitops/apps/observability/truenas-alerts/values.yaml`**

```yaml
app-template:
  controllers:
    truenas-alerts:
      type: deployment
      replicas: 1
      strategy: RollingUpdate
      containers:
        main:
          image:
            repository: quay.io/prometheuscommunity/json-exporter
            # Latest tagged release (Aug 2026). Verify with
            # `curl -s "https://quay.io/api/v1/repository/prometheuscommunity/json-exporter/tag/?onlyActiveTags=true"`.
            tag: "v0.8.0"
          args:
            - --config.file=/etc/json-exporter/config.yml
          probes:
            liveness:
              enabled: true
              custom: true
              spec:
                httpGet:
                  path: /metrics
                  port: 7979
                periodSeconds: 30
                initialDelaySeconds: 10
            readiness:
              enabled: true
              custom: true
              spec:
                httpGet:
                  path: /metrics
                  port: 7979
                periodSeconds: 10
                initialDelaySeconds: 5
            startup:
              enabled: false
          resources:
            requests:
              cpu: 20m
              memory: 64Mi
            limits:
              memory: 128Mi

  service:
    # Single ClusterIP service — vmagent scrapes /probe on :7979 via the
    # VMServiceScrape in templates/. With one service, app-template names
    # it after the release (`truenas-alerts`), which becomes the `job`
    # label the truenas.yaml rules match on.
    main:
      controller: truenas-alerts
      ports:
        http:
          port: 7979

  persistence:
    # json_exporter module config — hand-written ConfigMap in templates/
    # (sibling pattern: truenas-exporter's mapping ConfigMap).
    config:
      enabled: true
      type: configMap
      name: truenas-alerts-config
      globalMounts:
        - path: /etc/json-exporter/config.yml
          subPath: config.yml
          readOnly: true
    # TrueNAS API key file — Secret synced from OpenBao by the
    # ExternalSecret in templates/; referenced by credentials_file in
    # the json_exporter config.
    api-key:
      enabled: true
      type: secret
      name: truenas-alerts-api-key
      globalMounts:
        - path: /etc/json-exporter/secrets/api-key
          subPath: api-key
          readOnly: true
```

- [ ] **Step 3: Write `gitops/apps/observability/truenas-alerts/templates/namespace.yaml`**

The ApplicationSet deploys each dir with destination namespace = dir basename + `CreateNamespace=true`; shipping our own Namespace adds the baseline PSA labels (json_exporter needs no privileges). Identical pattern to grafana / vm-system / truenas-exporter:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: truenas-alerts
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

- [ ] **Step 4: Fetch the dependency (creates Chart.lock; tarball is gitignored)**

Run: `helm dependency update gitops/apps/observability/truenas-alerts`
Expected: `Saving 1 charts` / `Downloading app-template from repo https://bjw-s-labs.github.io/helm-charts/` and a new `Chart.lock` pinning `app-template 5.1.0`.

- [ ] **Step 5: Render and verify**

Run: `helm template truenas-alerts gitops/apps/observability/truenas-alerts`
Expected: renders without error; output contains a `kind: Deployment` (image `quay.io/prometheuscommunity/json-exporter:v0.8.0`), a `kind: Service` named exactly `truenas-alerts` (NOT `truenas-alerts-main` — if suffixed, the single service was not treated as primary; set `service.main.primary: true` in values.yaml and re-render), and the Namespace.

Run: `helm template truenas-alerts gitops/apps/observability/truenas-alerts | grep -A2 'kind: Service' && helm template truenas-alerts gitops/apps/observability/truenas-alerts | grep 'name: truenas-alerts$'`
Expected: Service name `truenas-alerts` present.

Run: `yamllint gitops/`
Expected: exit 0, no output.

- [ ] **Step 6: Commit**

```bash
git add gitops/apps/observability/truenas-alerts
git commit -m "feat(gitops): scaffold truenas-alerts app — json_exporter deployment

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: json_exporter config ConfigMap + API-key ExternalSecret

**Files:**
- Create: `gitops/apps/observability/truenas-alerts/templates/configmap-config.yaml`
- Create: `gitops/apps/observability/truenas-alerts/templates/externalsecret.yaml`

**Interfaces:**
- Consumes: mount paths from Task 1's values.yaml (`/etc/json-exporter/config.yml`, `/etc/json-exporter/secrets/api-key`); ConfigMap name `truenas-alerts-config` and Secret name `truenas-alerts-api-key` referenced there.
- Produces: json_exporter module named `truenas` (Task 3's VMServiceScrape passes `module: [truenas]`); metric `truenas_alert_active{level, klass}` (Task 4's rules); OpenBao path `secret/truenas-alerts/api-key`, property `key` (Task 5's policy line and the RUNBOOK seeding command).

- [ ] **Step 1: Write `gitops/apps/observability/truenas-alerts/templates/configmap-config.yaml`**

json_exporter v0.8.0 config schema: `modules.<name>.{metrics, http_client_config, headers, body, valid_status_codes}`; `http_client_config` is the standard prometheus/common HTTP client config (supports `authorization.credentials_file` and `tls_config.insecure_skip_verify`). JSONPath is Kubernetes client-go syntax. `/api/v2.0/alert/list` returns a top-level JSON array of alert objects with fields `level` (INFO/NOTICE/WARNING/ERROR/CRITICAL/ALERT/EMERGENCY), `klass` (e.g. Smart, VolumeStatus, ScrubFinished), `dismissed` (bool), `formatted`, `uuid`, `datetime`, `one_shot`.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: truenas-alerts-config
  namespace: truenas-alerts
  annotations:
    # Apply before the Deployment (implicit wave 0) so the volume mount
    # resolves on first pod start.
    argocd.argoproj.io/sync-wave: "0"
data:
  config.yml: |
    modules:
      truenas:
        metrics:
          # One series per active (undismissed) TrueNAS alert:
          #   truenas_alert_active{level="CRITICAL", klass="..."} 1
          # Dismissed alerts are excluded — dismissing in the TrueNAS UI
          # is the ack that should also silence Discord.
          - name: truenas_alert
            type: object
            help: Active (undismissed) TrueNAS alert, one series per alert
            path: '{ [?(@.dismissed == false)] }'
            labels:
              level: '{ .level }'
              klass: '{ .klass }'
            values:
              active: 1
        http_client_config:
          authorization:
            type: Bearer
            # Mounted from Secret truenas-alerts-api-key (OpenBao via
            # ExternalSecret) — see RUNBOOK.md for seeding.
            credentials_file: /etc/json-exporter/secrets/api-key
          tls_config:
            # 192.168.1.40 serves a self-signed cert (LAN mgmt UI).
            insecure_skip_verify: true
```

- [ ] **Step 2: Write `gitops/apps/observability/truenas-alerts/templates/externalsecret.yaml`**

Pattern: `gitops/apps/observability/vmalert/templates/externalsecret.yaml` (apiVersion `external-secrets.io/v1`, ClusterSecretStore `openbao`, wave 0). The ApplicationSet's `ignoreDifferences` already covers ESO-defaulted fields.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: truenas-alerts-api-key
  namespace: truenas-alerts
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: truenas-alerts-api-key
    creationPolicy: Owner
  data:
    - secretKey: api-key
      remoteRef:
        key: secret/truenas-alerts/api-key
        property: key
```

- [ ] **Step 3: Render and verify**

Run: `helm template truenas-alerts gitops/apps/observability/truenas-alerts | grep -E 'kind: (ConfigMap|ExternalSecret)'`
Expected: both kinds present.

Run: `helm template truenas-alerts gitops/apps/observability/truenas-alerts | grep -E 'credentials_file|insecure_skip_verify|dismissed'`
Expected: the three config lines render verbatim.

Run: `yamllint gitops/`
Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add gitops/apps/observability/truenas-alerts/templates
git commit -m "feat(gitops): json_exporter config + TrueNAS API-key ExternalSecret

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: VMServiceScrape + RUNBOOK.md

**Files:**
- Create: `gitops/apps/observability/truenas-alerts/templates/vmservicescrape.yaml`
- Create: `gitops/apps/observability/truenas-alerts/RUNBOOK.md`

**Interfaces:**
- Consumes: Service `truenas-alerts` / port `http` / label `app.kubernetes.io/name: truenas-alerts` (Task 1); module name `truenas` (Task 2).
- Produces: scrape job `truenas-alerts` with `instance="truenas"` — Task 4's `absent(up{job="truenas-alerts"})` guard and the meta TargetDown rule both key off it.

- [ ] **Step 1: Write `gitops/apps/observability/truenas-alerts/templates/vmservicescrape.yaml`**

App-local scrape convention: wave `"5"`, endpoint field `interval` (NOT `scrapeInterval` — the operator's admission webhook rejects it and blocks the whole app sync; broke PR 2). No vmagent changes needed (`serviceScrapeSelector: {}` + `selectAllByDefault: true`). `VMServiceScrape` is already in the CI kubeconform SKIP_KINDS list — no workflow change.

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: truenas-alerts
  namespace: truenas-alerts
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: truenas-alerts
  endpoints:
    - port: http
      # Probe endpoint: json_exporter fetches the TrueNAS alert list per
      # scrape. 60s is plenty for an alert feed and gentle on the NAS API.
      interval: 60s
      path: /probe
      params:
        module: [truenas]
        target: ["https://192.168.1.40/api/v2.0/alert/list"]
      relabelConfigs:
        # instance would default to the pod IP:port; the NAS name reads
        # better in alerts (same pattern as pve1 on the proxmox scrape).
        - targetLabel: instance
          replacement: truenas
```

- [ ] **Step 2: Write `gitops/apps/observability/truenas-alerts/RUNBOOK.md`**

Mirrors `gitops/apps/observability/vmalert/RUNBOOK.md`'s style (numbered one-time manual steps, then verify, then e2e). Note this chart keeps the RUNBOOK at the chart root like vmalert (truenas-exporter's lives under `files/` only because it ships alongside operator artifacts).

````markdown
# truenas-alerts — one-time manual setup

Everything is GitOps-managed except the TrueNAS API key. **Do §1–§2
BEFORE merging the PR** — the ExternalSecret is sync-wave 0: if it
can't resolve the OpenBao secret, ArgoCD marks the app Degraded,
exhausts its retry budget (~20 min), and will NOT retry on its own.
Recovery if merged first anyway: seed the secret, then
`kubectl -n argocd annotate application truenas-alerts
argocd.argoproj.io/refresh=hard --overwrite`.

## 1. Create the TrueNAS API key

1. Log in at `https://192.168.1.40` (admin user).
2. Click the user/settings icon (top right) → **API Keys** → **Add**.
3. Name: `json-exporter-alerts` → **Add** → copy the key NOW (it is
   shown once). Call it API_KEY.
4. Smoke-test from the Mac (self-signed cert, hence `-k`):

```bash
curl -sk -H "Authorization: Bearer $API_KEY" \
  https://192.168.1.40/api/v2.0/alert/list | jq 'length, .[0] | {level, klass, dismissed}'
```

Expected: a number (may be 0) and, if any alert exists, an object with
`level`/`klass`/`dismissed` fields. A 401 means the key is wrong; an
empty array `[]` is fine (no active alerts).

## 2. Seed OpenBao

OpenBao seals on every reboot — check status first and unseal if
needed (`./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json`).

```bash
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
OPENBAO_TOKEN=$(jq -r '.root_token' ~/secure/openbao-init.json)
export OPENBAO_TOKEN

# Grant external-secrets read on secret/data/truenas-alerts/* (the
# policy .hcl in this PR is the source of truth; no role rebind needed):
./scripts/openbao/apply-policy.sh observability-read

# Write the key. kv-put REPLACES the whole record — this path holds a
# single key, so that's fine:
./scripts/openbao/kv-put.sh truenas-alerts/api-key key="$API_KEY"
```

## 3. Verify after the PR merges

```bash
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
kubectl -n truenas-alerts get externalsecret truenas-alerts-api-key   # READY True
kubectl -n truenas-alerts get pods                                    # 1/1 Running
kubectl -n argocd get app truenas-alerts \
  -o jsonpath='{.status.sync.status} {.status.health.status}'         # Synced Healthy
# (also check .status.operationState for admission-webhook denials if not Synced)

# Probe end-to-end through the exporter:
kubectl -n truenas-alerts port-forward svc/truenas-alerts 7979:7979 &
curl -s 'localhost:7979/probe?module=truenas&target=https://192.168.1.40/api/v2.0/alert/list'
# Expect: HTTP 200 with `truenas_alert_active{...} 1` lines (or no
# truenas_alert lines at all when TrueNAS has zero active alerts —
# that plus 200 still proves auth + parse work).
kill %1
```

In VictoriaMetrics (Grafana → Explore, or the vmalert UI):
`up{job="truenas-alerts"} == 1` within one scrape interval.

## 4. End-to-end alert test

Cheapest real test: TrueNAS raises a `ScrubStarted`/`ScrubFinished`
one-shot alert on the next scheduled scrub, and any pool/SMART issue
appears immediately. To force one instead of waiting: in the TrueNAS
UI, **Storage → Scrub** the boot-pool (harmless, quick) and watch for
`truenas_alert_active{klass=~"Scrub.*"}` followed by a Discord message
from the TrueNASAlert rule. Dismissing the alert in the TrueNAS UI
resolves the series → `✅ resolved` message (send_resolved is on).

Optional hardening while you're in the UI: **Storage → Disks → Edit**
each HDD and set SMART temperature thresholds (e.g. Critical 50) —
overheating then surfaces through this same pipeline as a SMART alert
(there is no disk-temperature *metric* in VictoriaMetrics; see
docs/2026-09-09-add-truenas-health.md).
````

- [ ] **Step 3: Render and verify**

Run: `helm template truenas-alerts gitops/apps/observability/truenas-alerts | grep -E 'interval|module|target:|replacement'`
Expected: `interval: 60s`, `module:` with `truenas`, the alert/list URL, `replacement: truenas`. Confirm the word `scrapeInterval` appears NOWHERE: `helm template truenas-alerts gitops/apps/observability/truenas-alerts | grep -c scrapeInterval` → `0`.

Run: `yamllint gitops/`
Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add gitops/apps/observability/truenas-alerts
git commit -m "feat(gitops): scrape truenas-alerts probe via VMServiceScrape + runbook

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: truenas.yaml alert rules (vmalert app)

**Files:**
- Create: `gitops/apps/observability/vmalert/templates/rules/truenas.yaml`

**Interfaces:**
- Consumes: metric `truenas_alert_active{level, klass}` (Task 2), job `truenas-alerts` (Task 3), existing metric `cpu_temperature{job="truenas"}` (truenas-exporter app, verified live).
- Produces: alerts TrueNASCriticalAlert, TrueNASAlert, TrueNASMetricsStale, TrueNASAlertsExporterAbsent, delivered via the existing pipeline (VMAlert `selectAllByDefault: true` — no other wiring).

- [ ] **Step 1: Write `gitops/apps/observability/vmalert/templates/rules/truenas.yaml`**

Conventions from the sibling rule files: `namespace: vm-system`, sync-wave `"30"`, single-quoted exprs, Prometheus templating in annotations Helm-escaped as `{{ "{{ $labels.x }}" }}`.

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: truenas
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  groups:
    - name: truenas
      rules:
        # TrueNAS's own alert system (SMART results, pool degradation,
        # failed scrubs, ...) mirrored into Discord. One series per
        # active undismissed alert; dismissing in the TrueNAS UI is the
        # ack that resolves the Discord side too. No `for:` — TrueNAS
        # has already debounced before an alert reaches its list.
        # TrueNAS levels rank INFO < NOTICE < WARNING < ERROR <
        # CRITICAL < ALERT < EMERGENCY; CRITICAL-and-above page as
        # critical, the rest as warning.
        - alert: TrueNASCriticalAlert
          expr: 'truenas_alert_active{level=~"CRITICAL|ALERT|EMERGENCY"} > 0'
          labels:
            severity: critical
          annotations:
            summary: 'TrueNAS {{ "{{ $labels.level }}" }} alert: {{ "{{ $labels.klass }}" }}'
            description: 'TrueNAS reports an active {{ "{{ $labels.level }}" }}-level {{ "{{ $labels.klass }}" }} alert — details in the TrueNAS UI at https://192.168.1.40 (Alerts bell). Dismissing it there resolves this alert.'
        - alert: TrueNASAlert
          expr: 'truenas_alert_active{level!~"CRITICAL|ALERT|EMERGENCY"} > 0'
          labels:
            severity: warning
          annotations:
            summary: 'TrueNAS {{ "{{ $labels.level }}" }} alert: {{ "{{ $labels.klass }}" }}'
            description: 'TrueNAS reports an active {{ "{{ $labels.level }}" }}-level {{ "{{ $labels.klass }}" }} alert — details in the TrueNAS UI at https://192.168.1.40 (Alerts bell). Dismissing it there resolves this alert.'
        # The netdata→graphite push path (truenas-exporter app) has no
        # `up` series, so TargetDown can't see it stalling. absent()
        # fires once samples go stale (~5m) and latches until data
        # returns. (The design spec sketched a timestamp()-based expr;
        # that returns no data — and so never fires — once the series
        # ages out of the instant-query lookbehind, which happens at
        # the same ~5m mark. absent() is the working form.)
        - alert: TrueNASMetricsStale
          expr: 'absent(cpu_temperature{job="truenas"})'
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: TrueNAS netdata metrics are stale
            description: No fresh cpu_temperature samples from job truenas for 10+ minutes — the netdata→graphite push from TrueNAS has stalled (TrueNAS reporting exporter, netdata service, or the graphite LoadBalancer path). Dashboards and temperature history are blind.
        # Safety net for the new scrape job itself: if the
        # VMServiceScrape or Service vanishes, `up` has no series and
        # neither TargetDown nor the rules above can fire. Same
        # precedent as PlexExporterAbsent / ProxmoxMetricsAbsent.
        - alert: TrueNASAlertsExporterAbsent
          expr: 'absent(up{job="truenas-alerts"})'
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: truenas-alerts scrape job is missing
            description: No up{job="truenas-alerts"} series for 10+ minutes — the json_exporter scrape config itself is gone and TrueNAS health alerts are unmonitored.
```

- [ ] **Step 2: Render and verify the Helm escaping**

Run: `helm template vmalert gitops/apps/observability/vmalert | grep -F '{{ $labels.klass }}'`
Expected: literal `{{ $labels.klass }}` lines (the escape rendered correctly).

Run: `helm template vmalert gitops/apps/observability/vmalert | grep -c 'alert: TrueNAS'`
Expected: `4`.

Run: `yamllint gitops/`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add gitops/apps/observability/vmalert/templates/rules/truenas.yaml
git commit -m "feat(gitops): TrueNAS health alert rules

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: OpenBao policy extension

**Files:**
- Modify: `scripts/openbao/policies/observability-read.hcl` (currently 2 path lines at the bottom)

**Interfaces:**
- Consumes: OpenBao path `secret/truenas-alerts/api-key` chosen in Task 2 (KV v2 data path = `secret/data/truenas-alerts/*`).
- Produces: read grant for the `external-secrets` auth role (already bound to this policy — extending the .hcl + `apply-policy.sh` is all a new path needs, no role rebind).

- [ ] **Step 1: Add the path line**

In `scripts/openbao/policies/observability-read.hcl`, after the line `path "secret/data/vmalert/*" { capabilities = ["read"] }`, add:

```hcl
path "secret/data/truenas-alerts/*" { capabilities = ["read"] }
```

(The file's header comment already documents the apply procedure; no comment changes needed.)

- [ ] **Step 2: Verify**

Run: `grep -c 'capabilities = \["read"\]' scripts/openbao/policies/observability-read.hcl`
Expected: `3`.

- [ ] **Step 3: Commit**

```bash
git add scripts/openbao/policies/observability-read.hcl
git commit -m "feat(secrets): grant observability-read on secret/truenas-alerts/*

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Docs entry

**Files:**
- Create: `docs/2026-09-09-add-truenas-health.md`

**Interfaces:**
- Consumes: everything above (summarizes it).
- Produces: the repo-mandated docs entry. `#TBD` PR number MUST be replaced before merge (verify the PR is still open with `gh pr view` first, per standing feedback).

- [ ] **Step 1: Write `docs/2026-09-09-add-truenas-health.md`**

```markdown
# Add TrueNAS health alerts (json_exporter → TrueNAS alert list)

**Date:** 2026-09-09
**PR:** [#TBD](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/TBD)
**Design:** docs/superpowers/specs/2026-09-08-cluster-monitoring-design.md (PR 3 of 3)

## What

- New GitOps app `gitops/apps/observability/truenas-alerts`:
  prometheus-community json_exporter (v0.8.0, quay.io tag verified
  against the registry) polling `https://192.168.1.40/api/v2.0/alert/list`
  and exposing `truenas_alert_active{level, klass}` — one series per
  active (undismissed) TrueNAS alert. Auth: TrueNAS API key as bearer
  token, OpenBao → ExternalSecret → Secret → file mount.
- `VMServiceScrape` (job `truenas-alerts`, 60s) — vmagent and CI needed
  no changes (selectAllByDefault; VMServiceScrape already in the
  kubeconform skip list).
- `truenas.yaml` VMRule in the vmalert app: TrueNASCriticalAlert
  (level CRITICAL/ALERT/EMERGENCY → critical), TrueNASAlert (all other
  levels → warning), TrueNASMetricsStale (netdata push stalled,
  warning), TrueNASAlertsExporterAbsent (scrape job vanished, warning).
  Delivery rides the PR-1 vmalert → Alertmanager → HA → Discord
  pipeline.
- OpenBao: `secret/truenas-alerts/api-key` + one read-grant line in
  `observability-read.hcl`. One-time API-key/seeding steps in the
  app's RUNBOOK.md (done before merge).

## Why this shape

- Mirroring TrueNAS's own alert list (design decision 4) surfaces
  SMART failures, pool degradation, and every other TrueNAS-detected
  problem through one metric — the HBA is passed through to the VM, so
  only TrueNAS can see the disks. Dismissing an alert in the TrueNAS
  UI is the ack that also resolves the Discord alert.
- **Deviation: the spec's TrueNASDiskTempHigh rule was dropped.** It
  assumed a `disk_temperature{job="truenas"}` metric; live queries
  show the netdata→graphite path has never shipped one (only
  cpu_temperature and disk I/O). Disk-overheat coverage comes via
  TrueNAS smartd temperature alerts through this same pipeline once
  thresholds are set in the UI (RUNBOOK §4 documents it).
- **Deviation: TrueNASMetricsStale uses `absent()`** instead of the
  spec's `timestamp()`-based expression, which can never fire — the
  series ages out of the instant-query lookbehind at the same ~5m mark
  the threshold checks for, leaving the expression with no data.
- Two `- alert:` blocks with level matchers map TrueNAS severity to
  Alertmanager severity declaratively; no `for:` on them because
  TrueNAS has already debounced anything that reaches its alert list.

## Follow-ups

- Restore disk-temperature *metrics* (netdata smartd/disktemp
  collection in the truenas-exporter path), then a TrueNASDiskTempHigh
  rule is a one-file PR.
- Dead-man's-switch for the alerting pipeline itself (HA-side
  heartbeat timer) — deliberately out of scope in the design.
```

- [ ] **Step 2: Commit**

```bash
git add docs/2026-09-09-add-truenas-health.md
git commit -m "docs: add TrueNAS health alerts entry

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Full verification pass (no new files)

- [ ] **Step 1: Replicate CI locally over the touched charts**

```bash
yamllint gitops/
helm dependency update gitops/apps/observability/truenas-alerts >/dev/null
helm template truenas-alerts gitops/apps/observability/truenas-alerts >/dev/null && echo RENDER-OK-truenas-alerts
helm template vmalert gitops/apps/observability/vmalert >/dev/null && echo RENDER-OK-vmalert
```

Expected: no yamllint output, both `RENDER-OK` lines.

- [ ] **Step 2: Escaping + field-name sweep**

```bash
# Literal Prometheus templating must survive rendering:
helm template vmalert gitops/apps/observability/vmalert | grep -cF '{{ $labels.level }}'   # >= 4
# No unescaped Helm-eaten annotations (an empty summary would render as `summary: ""` or drop the var):
helm template vmalert gitops/apps/observability/vmalert | grep -n 'summary:.*\$labels' | head
# The webhook-rejected field name must not appear anywhere new:
grep -rn 'scrapeInterval' gitops/apps/observability/truenas-alerts/ && echo FAIL || echo OK
```

Expected: count ≥ 4; summaries show `{{ $labels.* }}`; `OK`.

- [ ] **Step 3: Confirm no CI workflow change is needed**

Run: `grep -o 'VMServiceScrape' .github/workflows/gitops.yml | head -1`
Expected: `VMServiceScrape` (already in SKIP_KINDS — this task adds no new CRD kinds).

- [ ] **Step 4: Push branch and open the PR**

Follow superpowers:finishing-a-development-branch / repo conventions: push `feat/truenas-health`, open a PR titled `feat: TrueNAS health alerts — json_exporter + rules (PR 3/3)` whose body summarizes the What/Why (including the two spec deviations), links the design spec, and ends with the Claude Code attribution line. Then update `docs/2026-09-09-add-truenas-health.md` replacing `#TBD` with the real PR number (verify the PR is still open with `gh pr view` before pushing the follow-up commit):

```bash
git commit -am "docs: fill TrueNAS health PR number

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Manual steps (need the user / live systems — BEFORE merge)

Sequenced exactly as RUNBOOK.md §1–§2 (Task 3). Summary for the driver:

1. User (or guided): create TrueNAS API key `json-exporter-alerts` at `https://192.168.1.40`, smoke-test with the RUNBOOK curl.
2. Check `bao status` (OpenBao seals on every reboot; `./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json` if sealed).
3. `./scripts/openbao/apply-policy.sh observability-read` (picks up the Task 5 .hcl from this branch's checkout).
4. `./scripts/openbao/kv-put.sh truenas-alerts/api-key key=<API_KEY>` — single key, so kv-put's replace semantics are fine.
5. Only then merge the PR (squash-merge, per repo convention).

## Post-merge verification (RUNBOOK §3–§4)

- ArgoCD: `truenas-alerts` app Synced/Healthy; on failure check `kubectl -n argocd get app truenas-alerts -o jsonpath='{.status.operationState}'` for admission-webhook denials (schemaless CRDs make this the first place typos surface).
- VictoriaMetrics (Grafana MCP datasource uid `P4169E866C3094E38`): `up{job="truenas-alerts"} == 1`. If the job label rendered differently (e.g. `truenas-alerts-main`), fix is one line in Task 3's selector/relabel + Task 4's absent-guard — but Task 1 Step 5 should have caught a suffixed Service name already.
- `truenas_alert_active` present (or confirmed-empty probe per RUNBOOK §3), `kubectl -n vm-system get vmrule` lists `truenas`.
- E2E per RUNBOOK §4 (boot-pool scrub → Discord firing + resolved messages).
