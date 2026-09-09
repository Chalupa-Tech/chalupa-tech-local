# Cluster Health Monitoring — Design

**Date:** 2026-09-08
**Status:** Approved (pending implementation)

## Goal

Add alerting ("monitors") for the health of the homelab: Plex uptime, *arr
uptime, Proxmox host metrics (CPU, memory, temperatures), and TrueNAS
SMART/health — with a pattern that makes future monitors a one-file change.

Dashboards already exist; nothing *watches* them today. There is no vmalert,
no Alertmanager, and zero alert rules anywhere in the stack.

## Current state (verified 2026-09-08)

- Observability stack: VictoriaMetrics single + vmagent + VictoriaLogs +
  Grafana, all in `gitops/apps/observability/`, deployed via ArgoCD.
  victoria-metrics-operator installs the `VMAlert`, `VMAlertmanager`, and
  `VMRule` CRDs already (`vm-system/values.yaml` — `crds.create: true`).
- Metrics that already exist:
  - `plex_up` (plex-exporter, job `plex-exporter`)
  - `scraparr_services_up` (scraparr, job `scraparr`)
  - `disk_temperature`, `cpu_temperature`, disk I/O for TrueNAS
    (netdata → graphite → truenas-exporter, job `truenas`)
  - node-exporter on the 3 Talos workers (job `prometheus-node-exporter`)
- Gaps:
  - No metrics from the Proxmox host (pve1) itself — no CPU/mem/temp data.
  - No SMART *health* indicators from TrueNAS (temperature only; the HBA is
    passed through to the VM, so only TrueNAS can see the disks).
  - No alerting or notification path at all.
- Home Assistant has a Discord bot integration exposed as
  `notify.homeassistant_tejon_frame`; `pyscript/climate_balance.py` already
  sends Discord messages through it with a channel-ID `target`.

## Architecture

```
metrics (existing + 2 new collectors)          alerting (new)                 delivery (new)
─────────────────────────────────────          ──────────────                 ─────────────
plex_up ─────────────┐
scraparr_services_up ─┤                        vmalert ──► Alertmanager ──► HA webhook ──► notify.homeassistant_tejon_frame
node-exporter @ pve1 ─┼──► vmagent ──► vmsingle ──▲                             (pyscript)          └─► Discord channel
truenas json_exporter ┘                     VMRule files (one per concern)
```

### Decisions made (with alternatives considered)

1. **Rule engine: vmalert + Alertmanager via VM-operator CRs** (chosen) vs
   Grafana unified alerting (alert state outside Git, clunky provisioning) vs
   Uptime Kuma (uptime-only; can't see PromQL metrics). Chosen because rules
   become plain YAML in the GitOps repo, PR-reviewed, fully rebuildable.
2. **Delivery: Discord via the existing HA bot** (user choice). Alertmanager
   can't speak HA's notify format directly, so an HA webhook-trigger bridges
   it. Pyscript is used (not a UI automation) so the bridge lives in Git.
3. **Proxmox collection: node-exporter on the host** (chosen) vs pve-exporter
   (API-based; per-VM visibility but no temperatures) vs both. node-exporter
   covers the asked-for CPU/mem/temps with one Ansible task-set.
4. **TrueNAS SMART: mirror TrueNAS's own alert list via its REST API**
   (chosen) vs smartctl_exporter as a TrueNAS custom app (granular raw
   attributes, but a manually-managed app outside GitOps) vs disk-temp-only
   (misses real failure indicators). TrueNAS already runs scheduled SMART
   tests; polling `/api/v2.0/alert/list` surfaces SMART failures *and* pool
   degradation and every other TrueNAS-detected problem through one metric.

## Components

### 1. `gitops/apps/observability/vmalert` — new GitOps app

Helm chart (templates-only, like other local apps), deploying into the
`vm-system` namespace (no new namespace):

- **`VMAlertmanager` CR** — 1 replica, small resources. Config via the VM
  operator's config-secret mechanism; the HA webhook URL is referenced
  through a Secret (`url_secret`) so the webhook ID never lands in Git.
- **`VMAlert` CR** — datasource + remote read/write pointed at the existing
  vmsingle; notifier pointed at the Alertmanager; rule selector picks up all
  `VMRule` objects in the namespace.
- **ExternalSecret** — pulls the HA webhook URL from OpenBao.
- **`templates/rules/*.yaml`** — one `VMRule` file per concern (see rule set
  below). **Adding a future monitor = adding one file here** (or one more
  `- alert:` block in an existing file) and merging a PR.

Routing config: single Discord receiver; `group_by: [alertname]`;
`send_resolved: true`; `repeat_interval: 12h` so a stuck alert re-pings
roughly daily instead of spamming.

ArgoCD's existing directory-based ApplicationSet discovers the new app dir
automatically; the existing lint/render required checks cover it in CI.

### 2. HA delivery bridge — `homeassistant/pyscript/vmalert_discord.py`

- `@webhook_trigger("<webhook-id>")` receives Alertmanager's webhook POSTs at
  `http://192.168.1.234:8123/api/webhook/<webhook-id>`. The webhook ID is a
  long random string and acts as the shared secret (HA webhooks are
  unauthenticated by design; LAN-only exposure).
- Formats each firing/resolved alert: severity emoji, alert name, `summary`/
  `description` annotations, 🔥 for firing / ✅ for resolved.
- Calls `notify.homeassistant_tejon_frame` with `target: <alerts-channel-id>`
  — a dedicated Discord channel, following the same hardcoded-constant
  pattern as `climate_balance.py` (`_DISCORD_TARGET`).
- Pyscript constraints apply (module-level helpers, no closures over params —
  see existing memory/feedback).

Known tradeoff: if HA is down, alerts don't deliver. Alertmanager retries
webhooks, so brief HA restarts are fine. Accepted for homelab; the escape
hatch later is a second receiver (e.g. a direct Discord channel webhook).

### 3. Proxmox host collector

- **Ansible** (`proxmox_prep` role): install Debian's
  `prometheus-node-exporter` package on pve1, service enabled + started.
  Listens on `:9100` (LAN-only host).
- **Scrape** — `VMStaticScrape` in `gitops/apps/observability/vm-system/
  templates/` targeting `192.168.1.223:9100`, job `proxmox-host`, instance
  relabeled to `pve1`.
- Provides `node_cpu_seconds_total`, `node_memory_*`, and
  `node_hwmon_temp_celsius` (k10temp on the AMD Strix Halo).

### 4. TrueNAS health collector — `gitops/apps/observability/truenas-alerts`

- prometheus-community **json_exporter** (image + tag verified against the
  registry at implementation time, per standing feedback) polling
  `https://192.168.1.40/api/v2.0/alert/list`.
- Auth: TrueNAS API key, created once in the TrueNAS UI, stored in OpenBao,
  delivered by ExternalSecret, injected into json_exporter's HTTP client
  config as a bearer token.
- Output metric: `truenas_alert_active{level, klass}` — one series per
  active TrueNAS alert (level = INFO/WARNING/CRITICAL etc., klass = the
  TrueNAS alert class, e.g. SMART, VolumeStatus).
- `RUNBOOK.md` in the app dir documents the API-key creation step, mirroring
  the existing truenas-exporter runbook.

## Initial rule set

| File | Alert | Condition | Severity |
|---|---|---|---|
| `plex.yaml` | PlexDown | `plex_up == 0` for 5m | critical |
| | PlexExporterAbsent | `absent(plex_up)` for 10m | warning |
| `arrs.yaml` | ArrServiceDown | `scraparr_services_up == 0` for 5m (service name in message) | critical |
| | ScraparrAbsent | `absent(scraparr_services_up)` for 10m | warning |
| `proxmox-host.yaml` | ProxmoxHostDown | `up{job="proxmox-host"} == 0` for 5m | critical |
| | ProxmoxHighCPU | avg CPU > 90% for 15m | warning |
| | ProxmoxHighMemory | memory used > 92% for 10m | warning |
| | ProxmoxHighTemp | k10temp > 85°C for 10m | warning |
| | ProxmoxCriticalTemp | k10temp > 95°C for 5m | critical |
| `truenas.yaml` | TrueNASAlert | `truenas_alert_active > 0` (TrueNAS level CRITICAL → critical, everything else → warning) | mapped |
| | TrueNASDiskTempHigh | `disk_temperature > 45` for 15m | warning |
| | TrueNASMetricsStale | no fresh netdata samples for 5m, e.g. `(time() - max(timestamp(cpu_temperature{job="truenas"}))) > 300` | warning |
| `meta.yaml` | TargetDown | `up == 0` for 10m, any job | warning |

Notes:
- `TargetDown` is the safety net: any current or *future* exporter dying is
  caught without writing a dedicated rule.
- Every alert carries `summary` and `description` annotations — that text is
  what lands in Discord.
- Thresholds are starting points; tuning is a one-line PR.

## Secrets (OpenBao)

Three new entries, written with `bao kv patch` (never `put` — it wipes
sibling keys):

| Secret | Consumer | Path delivery |
|---|---|---|
| HA webhook URL (contains webhook ID) | Alertmanager | ExternalSecret → Secret → `url_secret` |
| Discord alerts-channel ID | pyscript constant (hardcoded like climate_balance) | n/a — documented only |
| TrueNAS API key | json_exporter | ExternalSecret → Secret → bearer-token file |

Manual one-time steps (documented in runbooks): create the Discord alerts
channel and note its ID; generate the TrueNAS API key; seed OpenBao.

## Testing

- CI: existing lint/render required checks cover the new chart dirs.
- End-to-end: a temporary `AlwaysFiring` rule (`expr: vector(1)`) proves the
  full path vmalert → Alertmanager → HA pyscript → Discord message, then is
  removed. Resolved-notification path verified by deleting the rule.
- Collector verification: `up{job="proxmox-host"} == 1`;
  `truenas_alert_active` present (fire a harmless TrueNAS test alert or
  confirm zero-value scrape success metric).

## Rollout (3 PRs, each independently useful)

1. **PR 1 — alerting core + delivery:** vmalert app (VMAlert, Alertmanager,
   ExternalSecret), pyscript bridge, `plex.yaml` + `arrs.yaml` + `meta.yaml`
   rules (all metrics already exist), end-to-end test.
2. **PR 2 — Proxmox host:** Ansible node-exporter task, VMStaticScrape,
   `proxmox-host.yaml` rules.
3. **PR 3 — TrueNAS health:** truenas-alerts app, OpenBao/API-key runbook,
   `truenas.yaml` rules.

Each PR gets a `docs/` entry (or extends one) with rationale + PR link, per
repo rules.

## Out of scope (deliberately)

- Watchdog/dead-man's-switch for the alerting pipeline itself (HA-side timer
  noticing a heartbeat stopped). Noted as a future monitor.
- pve-exporter per-VM metrics.
- Raw SMART attributes via smartctl_exporter on TrueNAS.
- New Grafana dashboards (existing ones already cover these metrics).
