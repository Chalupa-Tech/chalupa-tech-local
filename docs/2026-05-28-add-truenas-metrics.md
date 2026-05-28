# 2026-05-28: Add TrueNAS Metrics to Grafana

## Overview

Expose TrueNAS Scale (192.168.1.40) metrics in the existing
VictoriaMetrics/Grafana stack via the push-based Graphite path. TrueNAS
Reporting → Exporters pushes Netdata-shaped Graphite metrics at a
`graphite_exporter` running in the cluster; vmagent scrapes the
exporter's `/metrics` endpoint and renders five upstream-supplied
dashboards.

No API key, no Bao entry, no pull-based exporter. The only TrueNAS-side
state is a Reporting → Exporters row and one config file.

## What changed

Two new artifacts under `gitops/`:

- **`gitops/apps/observability/truenas-exporter/`** — bjw-s
  `app-template` 4.4.0 wrapper.
  - Image: `prom/graphite-exporter:v0.16.0` (official Prometheus image,
    Oct 2024).
  - `graphite_mapping.conf` and `netdata.conf` under `files/` are pinned
    copies of `Supporterino/truenas-graphite-to-prometheus` v2.2.1
    (Nov 2025). The mapping translates Netdata's Graphite metric names
    into Prometheus form; the netdata.conf is an operator-only artifact
    for the one-time `scp` to the TrueNAS host (TrueNAS 25.04 stripped
    many default metrics and this restores them).
  - Two Services:
    - `truenas-exporter-main` (ClusterIP, :9108) — Prometheus `/metrics`,
      scraped by vmagent via the VMServiceScrape.
    - `truenas-exporter-graphite` (LoadBalancer, MetalLB-pinned to
      `192.168.1.161`, TCP :9109) — graphite text protocol ingest,
      TrueNAS pushes here.
  - VMServiceScrape selects only the `main` Service (filtered by
    `app.kubernetes.io/service` since both Services share
    `app.kubernetes.io/name`), with `honorLabels: true` so the
    mapping-emitted `job="truenas"` and `instance` labels survive
    vmagent's relabeling.
- **`gitops/apps/observability/grafana/dashboards/truenas-*.json`** +
  matching `templates/dashboards/truenas-*.tpl` — five dashboards from
  the upstream `v2.2.1` `dashboards/` folder:
  - `truenas-overview.json` ("TrueNAS Scale / Overview")
  - `truenas-disks.json` ("TrueNAS Scale - Disk Insight")
  - `truenas-temperatures.json` ("TrueNAS Scale - Temperature Overview")
  - `truenas-cgroups.json` ("TrueNAS Scale / CGroups/Containers")
  - `truenas-apps-k3s.json` ("TrueNAS Scale - Applications (k3s)")

  Each JSON was patched at import: `__inputs` removed, the `DS_MIMIR`
  templating variable removed, and `${DS_MIMIR}` literals rewritten to
  `VictoriaMetrics` (the UID of the existing datasource). Without this
  step the sidecar-loaded dashboards would render "Datasource not
  found" until manually re-selected per panel.

`gitops/bootstrap/applicationsets/observability.yaml` is unchanged: the
existing directory generator (`gitops/apps/observability/*`) picks up
the new chart automatically, and the grafana sidecar's
`searchNamespace: ALL` discovers the new dashboard ConfigMaps without
edit.

## Why graphite-push, not an API exporter

Initial pitch was a pull-based API exporter (auth via OpenBao). On
research the API-exporter ecosystem turned out to be either stale,
unmaintained, or shipping no container image. The graphite-push path is
the actively-maintained one:

- TrueNAS Scale itself supports it as a first-class Reporting backend
  (since 23.10.1).
- `Supporterino/truenas-graphite-to-prometheus` ships a mapping +
  dashboards in lockstep with TrueNAS Scale releases (v2.x covers
  25.04+).
- `prom/graphite-exporter` is a tier-1 Prometheus project, so the
  cluster-side moving part is stable.
- No secret to roll, no API key to expire, no Bao entry to maintain.

Tradeoff: TrueNAS needs two one-time manual touches (Reporting UI
config + `netdata.conf` drop) and the netdata.conf must be re-applied
after each TrueNAS update.

## Network

| | |
|---|---|
| graphite ingest IP (cluster, MetalLB) | `192.168.1.161:9109` |
| TrueNAS source | `192.168.1.40` |
| graphite_exporter `/metrics` (in-cluster only) | `:9108` |

`192.168.1.161` is taken from the existing MetalLB default pool
`192.168.1.160-192.168.1.170` (Traefik's `.230` is separately pinned, so
nothing else in the pool is claimed today).

## Operator runbook (post-merge)

See `gitops/apps/observability/truenas-exporter/files/RUNBOOK.md` for
the per-step TrueNAS UI walkthrough and the `scp` command for the
netdata.conf. Summary:

1. ArgoCD syncs `truenas-exporter` → pod Healthy, MetalLB assigns
   `192.168.1.161`.
2. TrueNAS UI → Reporting → Exporters → add Graphite reporter pointed
   at `192.168.1.161:9109`, prefix `truenas`, hostname `truenas`.
3. `scp gitops/apps/observability/truenas-exporter/files/netdata.conf
   admin@192.168.1.40:/tmp/`, copy onto `/etc/netdata/netdata.conf`,
   restart netdata.
4. Within one scrape interval (30 s) the five TrueNAS dashboards show
   data.

## Verification

- `kubectl -n argocd get application truenas-exporter` → `Synced/Healthy`.
- `kubectl -n truenas-exporter get svc truenas-exporter-graphite` →
  `EXTERNAL-IP   192.168.1.161`.
- `kubectl -n vm-system port-forward svc/vmagent-vmagent-chalupa 8429:8429`
  → `curl -s localhost:8429/api/v1/targets | jq '.data.activeTargets[]
  | select(.scrapePool | contains("truenas"))'` → one entry, `health: up`.
- Grafana → "TrueNAS Scale / Overview" → panels populate.

## Risks / known limitations

- `netdata.conf` is wiped on every TrueNAS update — re-apply via the
  RUNBOOK after each. Upstream is tracking a persistent fix.
- The mapping file is regex-heavy (~900 lines, all `match_type: regex`).
  graphite_exporter's docs note regex mappings are slower than glob
  mappings, but at single-host TrueNAS push rates (one sample every
  10 s) this is well within budget.
- All five dashboards expect at least one matching `instance` label;
  the empty state until step 2 of the runbook completes is bare panels,
  not panel errors.
- `app.kubernetes.io/service` is the discriminator between the two
  Services; if a future app-template version changes that label key,
  the VMServiceScrape selector needs updating (the pod will keep
  receiving graphite either way — only the scrape side is at risk).

## Links

- Upstream pinned tag: https://github.com/Supporterino/truenas-graphite-to-prometheus/tree/v2.2.1
- graphite_exporter: https://github.com/prometheus/graphite_exporter
- PR: (filled in on creation)
