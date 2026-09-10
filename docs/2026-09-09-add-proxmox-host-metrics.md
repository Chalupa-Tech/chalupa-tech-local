# Add Proxmox host metrics + alerts (node-exporter on pve1)

**Date:** 2026-09-09
**PR:** [#303](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/303)
**Design:** docs/superpowers/specs/2026-09-08-cluster-monitoring-design.md (PR 2 of 3)

## What

- Ansible (`proxmox_prep`): install Debian's `prometheus-node-exporter`
  on pve1, enabled + started, listening on :9100 (LAN-only host).
- `VMStaticScrape` (vm-system app) targeting 192.168.1.223:9100 as job
  `proxmox-host`, instance relabeled to `pve1`. vmagent needed no
  changes (`staticScrapeSelector: {}` + selectAllByDefault were already
  set).
- `proxmox-host.yaml` VMRule in the vmalert app: ProxmoxHostDown
  (critical, 5m), ProxmoxHighCPU (>90% for 15m), ProxmoxHighMemory
  (>92% for 10m), ProxmoxHighTemp (k10temp >85°C for 10m),
  ProxmoxCriticalTemp (>95°C for 5m). Delivery rides the PR-1
  vmalert → Alertmanager → HA → Discord pipeline.
- CI: `VMStaticScrape` added to the kubeconform skip list (schemaless
  vm-operator CRD, same rationale as the existing entries).

## Why this shape

- node-exporter over pve-exporter: covers the asked-for CPU/mem/temps
  with one Ansible task-set; pve-exporter's per-VM API view adds no
  temperature data (design decision 3).
- Temperature rules join `node_hwmon_temp_celsius` with
  `node_hwmon_chip_names{chip_name="k10temp"}` because the chip label
  on the temperature series is a bus path, not a name.
- The host stays outside the cluster, so a static scrape (not a
  ServiceMonitor) is the natural fit; the exporter's death is covered
  both by ProxmoxHostDown and the PR-1 TargetDown safety net.

## Follow-ups

- PR 3: TrueNAS health (json_exporter polling /api/v2.0/alert/list).
