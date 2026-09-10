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
