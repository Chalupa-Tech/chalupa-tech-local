# Add cluster alerting: vmalert + Alertmanager + Discord delivery

**Date:** 2026-09-08
**PR:** [#300](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/300)
**Design:** docs/superpowers/specs/2026-09-08-cluster-monitoring-design.md (PR 1 of 3)

## What

- New GitOps app `gitops/apps/observability/vmalert`: VMAlert +
  VMAlertmanager + VMAlertmanagerConfig CRs (operator CRDs already
  installed by vm-system), an ExternalSecret for the HA webhook URL,
  and VMRule files for Plex, the *arr stack, and a TargetDown safety
  net. Adding a future monitor = one file under `templates/rules/`.
- Delivery: Alertmanager → HA webhook → pyscript app
  `vmalert_discord` → Discord alerts channel (via the existing
  `notify.homeassistant_tejon_frame` bot).
- One-time manual setup (webhook ID, Discord channel, OpenBao seed,
  HAOS config) documented in the app's RUNBOOK.md.

## Why this shape

- Rules as VMRule YAML in Git: PR-reviewed, rebuildable, no alert
  state outside the repo (vs Grafana unified alerting / Uptime Kuma).
- Discord via the existing HA bot (user choice); Alertmanager can't
  speak HA's notify format, so a pyscript webhook bridges it — in Git,
  unlike a UI automation. If HA is down, alerts don't deliver;
  accepted for homelab (Alertmanager retries cover HA restarts).
- The webhook ID is the shared secret: it lives in HAOS secrets.yaml
  and OpenBao only (public repo). The spec sketched hardcoding it in
  the pyscript file; that contradicted its own "never lands in Git"
  requirement, so the bridge is a pyscript *app* configured via
  `pyscript.app_config` + `!secret`.
- `disableNamespaceMatcher: true` on VMAlertmanager: without it the
  operator scopes the Discord route to alerts labeled
  namespace=vm-system, silently dropping alerts about media-namespace
  metrics.
- Side effect: ArgoCD's CreateNamespace creates an empty `vmalert`
  namespace (ApplicationSet destination = dir basename) while all
  resources explicitly target vm-system. Harmless; revisit if the
  ApplicationSet ever grows per-app destination overrides.

## Follow-ups

- PR 2: Proxmox host node-exporter + rules.
- PR 3: TrueNAS health (json_exporter polling /api/v2.0/alert/list).
- Future: dead-man's-switch for the pipeline itself (HA-side heartbeat
  timer) — deliberately out of scope in the design.
