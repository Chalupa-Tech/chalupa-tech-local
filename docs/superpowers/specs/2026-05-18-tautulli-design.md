# Tautulli — Design

**Date:** 2026-05-18
**Status:** Implemented
**Sub-project:** Follow-on observability + media work; complements existing `plex-exporter` (PR #206) and `plex-overview` dashboard (PR #211).

## Context

Plex itself runs in the LXC at `192.168.1.224:32400` (outside the cluster). Live current-state metrics — sessions, transcodes, library counts — are already scraped from Plex directly via `axsuul/plex-media-server-exporter` (`gitops/apps/media/plex-exporter/`, deployed in PR #206) and visualized by the `plex-overview` dashboard (PR #211).

Tautulli is an analytics/history layer that sits on top of Plex's API and persists per-user watch history, daily playcount trends, top-titles reports, and other historical data Plex itself doesn't retain. It runs as its own web UI; that UI is the primary deliverable. A separate Prometheus exporter sidecar (`mm404/tautulli-exporter`) re-emits a small set of live metrics — notably bandwidth in kbps and direct-play/direct-stream/transcode breakdown — that Plex's own exporter does not expose, so the Tautulli Grafana dashboard fills that specific gap rather than duplicating `plex-overview`.

## Goals

- Run Tautulli in the existing `media` namespace on the Talos cluster, reachable in-browser at `https://tautulli.frame.chalupatech.com` with the wildcard cert + LAN-only DNS (matches sonarr/radarr/seerr posture).
- Persist Tautulli config (its SQLite DB, settings, logs) on the shared `media-plexmedia` NFS PVC under `Configs/tautulli` — same convention as every other media app.
- Deploy `mm404/tautulli-exporter` as a standalone wrapper (mirroring `gitops/apps/media/plex-exporter/` shape), scrape it via `VMServiceScrape`, and ship a Grafana dashboard that complements (does not duplicate) `plex-overview`.
- Make the Tautulli pod usable on first deploy with **no** pre-merge OpenBao secret population. The operator pastes the Plex token via Tautulli's setup wizard on first login. The exporter is the only piece that needs a Bao secret, and it cleanly self-heals once the operator pastes the Tautulli API key in.

## Non-goals (explicitly out of scope)

- **Pre-seeding Tautulli's database or migrating an existing instance.** Fresh install. Operator runs through the setup wizard. No SQLite→Postgres migration (per project memory `feedback_pgloader_servarr_incompatible.md`; Tautulli isn't Postgres-backed anyway — it stays on SQLite).
- **OIDC / SSO.** Tautulli uses forms-based auth; operator creates an admin account on first visit.
- **Notification config / agents.** Push notifications, webhooks, Discord/Slack — operator UI work post-deploy.
- **Geoip / geolocation map of streams.** Tautulli supports this but requires a MaxMind API key the operator hasn't provisioned. Add later if wanted.
- **Removing or duplicating `axsuul/plex-media-server-exporter`.** Both exporters coexist; their metric names don't collide. The dashboard scope explicitly avoids panels already in `plex-overview`.
- **Public DNS for `tautulli.frame.chalupatech.com`.** LAN-only, matches every other media app per memory `project_cloudflare_rfc1918_filter.md`.

## Architecture

### Tiering

No new tier. Two new wrapper charts land at `gitops/apps/media/tautulli/` and `gitops/apps/media/tautulli-exporter/`; the existing `media-apps` ApplicationSet (`gitops/bootstrap/applicationsets/media.yaml`) picks both up via its `directories.path: gitops/apps/media/*` generator. The Grafana dashboard ConfigMap lands in `gitops/apps/observability/grafana/` and is loaded by the grafana sidecar via the `grafana_dashboard: "1"` label (matches the existing `plex-overview.tpl` pattern).

### Why two wrappers, not one sidecar in a single chart

`plex-exporter` is its own wrapper chart even though Plex itself isn't on the cluster — this repo's pattern is one wrapper per ArgoCD Application, scoped to a single concern. Splitting Tautulli and its exporter the same way means:

- Tautulli UI stays up even if the exporter sidecar CrashLoops (it will, until the operator pastes the API key post-first-run).
- The exporter's `ExternalSecret` can sit in `SecretSyncedError` indefinitely without flagging the Tautulli Application as Degraded.
- Each Application reports its own sync/health state in ArgoCD, matching the granularity of `plex-exporter` vs (hypothetical) `plex`.

### Tautulli wrapper

`gitops/apps/media/tautulli/`:

```
Chart.yaml          # depends on app-template 4.4.0
Chart.lock
.helmignore
values.yaml         # single deployment, PVC mount, web service
templates/
  └── ingressroute.yaml  # web → websecure redirect + websecure with TLS
```

**Image:** `lscr.io/linuxserver/tautulli` pinned to a real tag (current is `2.17.x-lsXXX` family; LSIO advised <=2.16.1 has CVEs). Tag verified at PR time per `feedback_verify_image_tag_on_registry`.

**Container env:**
- `TZ=America/Los_Angeles`
- `PUID=1000`, `PGID=1000` — matches the rest of the media tier.

**Probes:** httpGet on `/status` (Tautulli's health endpoint) at port 8181.

**Persistence:** one mount of the shared `media-plexmedia` PVC at `/config` subPath `Configs/tautulli` — matches sonarr/radarr/seerr. The subdirectory `/mnt/PlexMedia/frame/Configs/tautulli/` must exist; bjw-s app-template's subPath mounts require the path to exist beforehand. Operator step in the runbook.

**Service:** ClusterIP `tautulli:8181`.

**Ingress:** two IngressRoutes (`tautulli-http` + `tautulli-https`) matching the sonarr/radarr pattern, both annotated with `external-dns.alpha.kubernetes.io/target: "192.168.1.230"`. HTTP entryPoint uses the shared `redirect-to-https` middleware. HTTPS uses the default TLSStore wildcard cert.

### Tautulli-exporter wrapper

`gitops/apps/media/tautulli-exporter/`:

```
Chart.yaml          # depends on app-template 4.4.0
Chart.lock
.helmignore
values.yaml         # single deployment, env from secret, exporter port
templates/
  ├── externalsecret.yaml   # ESO → tautulli-exporter Secret from OpenBao
  └── vmservicescrape.yaml  # vmagent picks up via selectAllByDefault
```

**Image:** `mm404/tautulli-exporter` pinned to `0.2.4` (current stable on Docker Hub, 6 days old; `0.2.x` is the active release line). Source at `github.com/mm503/tautulli-exporter`. Verified live at design time.

**Container env:**
- `TAUTULLI_URL=http://tautulli.media.svc.cluster.local:8181` — in-cluster DNS to the Tautulli Service.
- `TAUTULLI_API_KEY` from secret `tautulli-exporter`, key `api-key` (ESO-synced from OpenBao `tautulli/exporter`, property `api-key`).
- `METRICS_PORT=8000` (default; explicit for clarity).
- `SCRAPE_INTERVAL=30s`, `LOG_LEVEL=INFO`.

**Probes:** httpGet on `/healthz` and `/ready` at port 8000 (exporter's own endpoints).

**Resources:** 20m CPU / 64Mi mem requests, 128Mi limit (mirrors `plex-exporter`).

**Service:** ClusterIP `tautulli-exporter:8000`.

**VMServiceScrape:** selects `app.kubernetes.io/name: tautulli-exporter`, scrapes port `http` at 30s. vmagent's `selectAllByDefault: true` picks it up automatically; metrics flow to vmsingle. Same shape as the `plex-exporter` VMServiceScrape.

**ExternalSecret:** `tautulli-exporter` reads OpenBao path `tautulli/exporter`, property `api-key`, sync interval 1h, sync wave `-1` so it (attempts to) reconcile before the Deployment. ESO will sit in `SecretSyncedError` until the operator populates the Bao path post-Tautulli-first-run — that's the expected initial state and is documented in the operator runbook.

### Grafana dashboard

`gitops/apps/observability/grafana/dashboards/tautulli-bandwidth.json` + `gitops/apps/observability/grafana/templates/dashboards/tautulli-bandwidth.tpl`. The .tpl mirrors the existing `plex-overview.tpl`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-tautulli-bandwidth
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  tautulli-bandwidth.json: |
{{- .Files.Get "dashboards/tautulli-bandwidth.json" | nindent 4 }}
```

**Scope (intentionally bounded to what mm404 emits that `axsuul/plex-media-server-exporter` does NOT):**

| Panel | Metric | Why it's here, not in `plex-overview` |
|---|---|---|
| Total bandwidth (kbps) — stat | `plex_bandwidth_total_kbps` | axsuul doesn't expose bandwidth in kbps |
| LAN vs WAN bandwidth — timeseries | `plex_bandwidth_lan_kbps`, `plex_bandwidth_wan_kbps` | new dimension |
| Stream type breakdown — pie | `plex_active_streams_direct_play`, `plex_active_streams_direct_stream`, `plex_active_streams_transcode` | new dimension |
| Transcode session detail — timeseries | `plex_transcode_video_sessions`, `plex_transcode_audio_sessions`, `plex_transcode_container_sessions` | finer-grained than axsuul's `plex_video_transcode_sessions_count` |
| Total active streams (sanity) — stat | `plex_active_streams_total` | overlap with `plex_sessions_count` in plex-overview; kept as a quick sanity check that both exporters agree |
| Note panel — markdown | n/a | links to Tautulli UI for historical reports (per-user, per-title, daily playcount) — those live in Tautulli's own DB, not in any exporter |

Datasource `VictoriaMetrics` (uid `VictoriaMetrics`), refresh 30s, time range `now-1h`. No template variables needed (single exporter target).

### Namespace + PSA

Reuses `media` namespace (baseline PSA — Tautulli and the exporter are non-root, no hostNetwork, no privileged caps; per memory `project_talos_psa_constraint.md` baseline is fine).

## Repository layout (additions only)

```
gitops/apps/media/tautulli/                                  NEW
├── Chart.yaml
├── Chart.lock
├── .helmignore
├── values.yaml
└── templates/
    └── ingressroute.yaml

gitops/apps/media/tautulli-exporter/                         NEW
├── Chart.yaml
├── Chart.lock
├── .helmignore
├── values.yaml
└── templates/
    ├── externalsecret.yaml
    └── vmservicescrape.yaml

gitops/apps/observability/grafana/dashboards/tautulli-bandwidth.json       NEW
gitops/apps/observability/grafana/templates/dashboards/tautulli-bandwidth.tpl  NEW

docs/2026-05-18-add-tautulli.md                              NEW (per CLAUDE.md "Document changes in docs/")
docs/superpowers/specs/2026-05-18-tautulli-design.md         NEW (this file)
```

No changes to:
- `gitops/bootstrap/applicationsets/media.yaml` — picks up the new directories automatically.
- `gitops/apps/media/plex-exporter/` — unchanged; runs alongside Tautulli.
- `gitops/apps/observability/grafana/dashboards/plex-overview.json` — unchanged; the new dashboard is complementary.

## Sync ordering and reconciliation

Per Application:

**`tautulli`** — single sync wave (default `0`):
- Deployment + Service + 2 IngressRoutes.

**`tautulli-exporter`** — two waves:
- Wave `-1`: `ExternalSecret tautulli-exporter` (ESO writes the `tautulli-exporter` Secret once OpenBao serves `tautulli/exporter`).
- Wave `0` (default): Deployment + Service + VMServiceScrape.

Initial state without operator action:
- Tautulli pod: `Running` immediately, UI fully usable, no Plex linkage yet.
- Tautulli-exporter pod: `CrashLoopBackOff` until the `tautulli-exporter` Secret exists. Argo retries (`limit: 5, backoff: 30s → 5m`) on the Application; the pod itself just keeps crashing until it can resolve the env var. The VMServiceScrape exists either way; vmagent will report scrape failures until the pod is up.

After operator runbook (below): both Applications `Synced/Healthy`, dashboard begins receiving data.

## Operator runbook

**Pre-merge:** none required. The PR is mergeable as-is; the operator can stage the OpenBao secret either before or after merge, the exporter just waits.

**Pre-merge optional (only if the operator wants the exporter healthy immediately on the very first sync — saves one CrashLoop cycle):** create the TrueNAS subdirectory:

```bash
# SSH to TrueNAS or use the Web UI
mkdir -p /mnt/PlexMedia/frame/Configs/tautulli
chown 1000:1000 /mnt/PlexMedia/frame/Configs/tautulli
```

(If skipped, Tautulli's pod will fail to mount and Argo retries until the directory exists. The shared NFS share already has writable Configs/ siblings for sonarr/radarr/seerr, so the bjw-s subPath mount creates the leaf as long as the parent is writable — but Tautulli will refuse to write to a missing path on first start, so making the dir up front is recommended.)

**Post-merge — first login flow:**

1. Wait for ArgoCD to mark `tautulli` Application `Synced/Healthy` (~30s after merge).
2. Browse to `https://tautulli.frame.chalupatech.com`. Tautulli setup wizard appears.
3. Step through the wizard:
   - **Admin account:** set username + password.
   - **Plex server:** paste the Plex token from the existing Plex setup. The token can be extracted from the existing Plex LXC at `192.168.1.224:32400` via the X-Plex-Token query string visible in the Plex Web UI after login. (Same token used by `axsuul/plex-media-server-exporter` — it lives in OpenBao at `plex/exporter`, property `token`, if the operator wants to grab it from there.)
   - **Server URL:** `http://192.168.1.224:32400` (Tautulli pod reaches Plex over the LAN, no DNS).
4. After the wizard, go to **Settings → Web Interface → API**. Copy the generated Tautulli API key.
5. Stash it in OpenBao:
   ```bash
   ./scripts/openbao/kv-put.sh tautulli/exporter api-key=<the-api-key>
   ```
   (Or use whatever path/script the operator normally uses to write to Bao.)
6. ESO syncs the secret within `refreshInterval: 1h` — or kick it immediately:
   ```bash
   kubectl -n media annotate externalsecret tautulli-exporter \
     force-sync=$(date +%s) --overwrite
   ```
7. Roll the exporter Deployment so it re-resolves env vars from the now-populated secret:
   ```bash
   kubectl -n media rollout restart deploy/tautulli-exporter
   ```
8. Within ~30s, vmagent scrapes the exporter and the dashboard begins receiving data.

## Verification

Run after the PR merges and the operator runbook completes:

1. `kubectl -n argocd get application tautulli tautulli-exporter` → both `Synced/Healthy`.
2. `kubectl -n media get pods -l app.kubernetes.io/name=tautulli` → `1/1 Ready`.
3. `kubectl -n media get pods -l app.kubernetes.io/name=tautulli-exporter` → `1/1 Ready` (post-runbook only).
4. `kubectl -n media get svc tautulli tautulli-exporter` → both ClusterIP, ports 8181 and 8000.
5. `kubectl -n media get externalsecret tautulli-exporter` → `SecretSynced`.
6. `kubectl -n media get secret tautulli-exporter` → has `api-key`.
7. `kubectl -n media get vmservicescrape tautulli-exporter` → present.
8. `kubectl -n media get ingressroute | grep tautulli` → two routes (`tautulli-http`, `tautulli-https`).
9. From LAN client:
   - `dig +short tautulli.frame.chalupatech.com` → `192.168.1.230`.
   - `curl -I https://tautulli.frame.chalupatech.com/status` → `HTTP/2 200`.
10. Browser to `https://tautulli.frame.chalupatech.com` → log in with the admin account set during the wizard.
11. Browser to Grafana → "Tautulli — Bandwidth & Streams" dashboard → bandwidth/transcode panels render with data (after a couple of scrape cycles).
12. `kubectl -n media exec deploy/tautulli-exporter -- wget -qO- http://localhost:8000/metrics | grep plex_bandwidth_total_kbps` → metric present with a value.

## Risks and mitigations

- **mm404/tautulli-exporter is a small, single-maintainer project.** The Docker Hub image is updated frequently (6 days at design time) but the GitHub repo is a typo'd vanity URL (`mm503/tautulli-exporter`, image namespace is `mm404`). Mitigation: pinned tag `0.2.4`, easy to fork if upstream goes dark. The 11 metrics are simple gauges — re-implementing in a Go-based exporter would be a small effort if ever needed.
- **Exporter metric names overlap partially with `axsuul/plex-media-server-exporter`** (`plex_*` prefix on both). They do **not collide** — different names — but a future panel author could accidentally pick the wrong source. Mitigation: dashboard panels in `tautulli-bandwidth.json` use only metric names unique to mm404 (`plex_bandwidth_*_kbps`, `plex_active_streams_direct_*`, `plex_transcode_*_sessions`). The overlap-on-purpose panel (`plex_active_streams_total` vs axsuul's `plex_sessions_count`) is a deliberate sanity check.
- **Tautulli's SQLite DB lives on NFS** (`media-plexmedia` share). SQLite over NFS is known to be fragile under concurrent writes. Tautulli only has one writer (its own process), so this is the safe case for SQLite-over-NFS. The shared NFS uses `soft,timeo=150,retrans=5` (same as sonarr/radarr); on a network blip the SQLite write retries. No HA Tautulli ever.
- **Exporter API key sits in OpenBao with no rotation policy.** Tautulli regenerates the API key on demand from its UI; rotation is a `bao kv patch` + `kubectl rollout restart`. Documented in the runbook.
- **`:latest` vs pinned tags.** Tautulli image is pinned to `2.17.x-lsXXX` (verified on registry at PR time, per memory). Exporter pinned to `0.2.4`. No `:latest` anywhere in this PR.
- **No backup of Tautulli's DB.** It lives on the NFS share; the operator's TrueNAS snapshot schedule already covers `/mnt/PlexMedia/frame` and therefore `Configs/tautulli` by extension. No new backup config needed.

## Open questions

None blocking. Resolved at implementation time:

- Exact pinned LSIO Tautulli tag (`2.17.x-lsXXX` family — verify on Docker Hub on PR day).
- Whether the operator pre-creates `/mnt/PlexMedia/frame/Configs/tautulli/` on TrueNAS or lets Tautulli create it on first NFS write — both work; pre-creating saves one pod restart.

## References

- Tautulli upstream: https://github.com/Tautulli/Tautulli
- LSIO Tautulli image: https://hub.docker.com/r/linuxserver/tautulli
- mm404/tautulli-exporter Docker Hub: https://hub.docker.com/r/mm404/tautulli-exporter
- mm503/tautulli-exporter source (typo'd vanity URL): https://github.com/mm503/tautulli-exporter
- Existing Plex exporter wrapper (closest pattern): `gitops/apps/media/plex-exporter/`
- Existing Plex overview dashboard (the one this complements): `gitops/apps/observability/grafana/dashboards/plex-overview.json` (PR #211)
- bjw-s app-template chart: https://github.com/bjw-s-labs/helm-charts/tree/main/charts/other/app-template
- Project conventions: `CLAUDE.md`
- Memory entries that shape this design:
  - `project_argocd_sync_config.md` — sync policy + retry behavior
  - `project_external_dns_target_annotation.md` — target annotation requirement
  - `project_cloudflare_rfc1918_filter.md` — public DNS posture (LAN only)
  - `project_talos_psa_constraint.md` — baseline PSA fine for these workloads
  - `feedback_pgloader_servarr_incompatible.md` — no DB migration, fresh start
  - `feedback_verify_image_tag_on_registry.md` — pinned tags only, registry-probed
