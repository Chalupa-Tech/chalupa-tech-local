# 2026-05-18: Add Tautulli + Tautulli Bandwidth Dashboard

## Overview

Deploy Tautulli (Plex history/analytics web UI) to the Talos cluster as
`tautulli.frame.chalupatech.com`, plus a sidecar Prometheus exporter
that complements the existing Plex monitoring with bandwidth-in-kbps
and playback-mode breakdown metrics that `axsuul/plex-media-server-exporter`
does not expose. A new Grafana dashboard ("Tautulli — Bandwidth &
Streams") surfaces the new metrics; the existing **Plex — Overview**
dashboard (PR #211) stays the place for live session counts, library
counts, and Plex server health.

## What changed

Three new wrappers / artifacts under `gitops/`:

- **`gitops/apps/media/tautulli/`** — bjw-s `app-template` 4.4.0 wrapper.
  - Image: `lscr.io/linuxserver/tautulli:v2.17.0-ls228` (pinned; LSIO
    advised <=2.16.1 has CVEs, so explicitly avoid `:latest` here even
    though sibling wrappers use it).
  - Config persisted on the shared `media-plexmedia` NFS PVC at
    `/config` (subPath `Configs/tautulli`).
  - Two IngressRoutes (`tautulli-http` → redirect, `tautulli-https`)
    pointed at `tautulli.frame.chalupatech.com` via the wildcard cert
    + external-dns target `192.168.1.230`.
- **`gitops/apps/media/tautulli-exporter/`** — separate wrapper so the
  exporter's CrashLoopBackOff (until the API key secret is populated)
  doesn't drag the Tautulli UI's Application down.
  - Image: `mm404/tautulli-exporter:0.2.4` (current stable; source at
    `github.com/mm503/tautulli-exporter` — vanity URL typo'd, but the
    image namespace `mm404` on Docker Hub is the canonical artifact).
  - Reads `TAUTULLI_API_KEY` from K8s Secret `tautulli-exporter`,
    which ESO syncs from OpenBao path `tautulli/exporter`,
    property `api-key`.
  - VMServiceScrape selects the exporter's `:8000` Service; vmagent
    (`selectAllByDefault: true`) picks it up cluster-wide.
- **`gitops/apps/observability/grafana/dashboards/tautulli-bandwidth.json`**
  + `templates/dashboards/tautulli-bandwidth.tpl` — 12-panel dashboard
  scoped to metrics mm404 exposes that axsuul does not (bandwidth
  total/LAN/WAN, direct-play vs direct-stream vs transcode breakdown,
  video/audio/container transcode session counts).

`gitops/bootstrap/applicationsets/media.yaml` and observability tier
are unchanged; the existing `media-apps` ApplicationSet's
`directories.path: gitops/apps/media/*` generator and the grafana
sidecar's `searchNamespace: ALL` pick up the new files automatically.

## Why two wrappers, not a sidecar in one chart

Every existing wrapper in `gitops/apps/media/` has a single concern.
`plex-exporter` is its own wrapper despite scraping Plex-the-LXC.
Splitting Tautulli the same way means:

- Tautulli UI stays Healthy in ArgoCD even while the exporter's
  `ExternalSecret` is in `SecretSyncedError` (initial state, until the
  operator's post-deploy step lands the Tautulli API key in OpenBao).
- Each Application's sync state reflects its own concern.
- The exporter can be removed / re-deployed / re-keyed without
  touching the Tautulli UI Application.

## Operator runbook (post-merge)

1. Wait for ArgoCD to mark the `tautulli` Application `Synced/Healthy`
   (~30s after merge). The `tautulli-exporter` Application will be
   `Synced` but the pod will `CrashLoopBackOff` — expected at this
   point.
2. Browse to `https://tautulli.frame.chalupatech.com` → step through
   the setup wizard:
   - Set the admin username + password.
   - Paste the Plex token (same one in OpenBao at `plex/exporter` →
     `token`, used by `axsuul/plex-media-server-exporter`).
   - Server URL: `http://192.168.1.224:32400`.
3. In Tautulli → **Settings → Web Interface → API**, copy the generated
   API key.
4. Stash it in OpenBao:
   ```bash
   ./scripts/openbao/kv-put.sh tautulli/exporter api-key=<the-api-key>
   ```
5. Force the ExternalSecret to sync immediately (otherwise it waits up
   to 1h):
   ```bash
   kubectl -n media annotate externalsecret tautulli-exporter \
     force-sync=$(date +%s) --overwrite
   ```
6. Roll the exporter Deployment so it re-resolves env from the now-
   populated Secret:
   ```bash
   kubectl -n media rollout restart deploy/tautulli-exporter
   ```

Within ~30s the exporter is `1/1 Ready`, vmagent scrapes it, and the
**Tautulli — Bandwidth & Streams** dashboard begins receiving data.

## Verification

- `kubectl -n argocd get application tautulli tautulli-exporter` → both
  `Synced/Healthy`.
- `kubectl -n media get pods -l app.kubernetes.io/name=tautulli` →
  `1/1 Ready`.
- `kubectl -n media get pods -l app.kubernetes.io/name=tautulli-exporter`
  → `1/1 Ready` (post-runbook).
- `curl -I https://tautulli.frame.chalupatech.com/status` → `HTTP/2 200`
  from a LAN client.
- Grafana → "Tautulli — Bandwidth & Streams" → panels render with data
  once the exporter is up and scrape cycles have elapsed.

## Risks / known limitations

- mm404/tautulli-exporter is a single-maintainer Docker image with a
  typo'd source URL (`mm503` user, `mm404` image namespace). Pinned tag
  `0.2.4` locks the artifact; if the image goes away, the 11 emitted
  gauges are simple to reproduce against the Tautulli HTTP API.
- Tautulli's SQLite DB lives on NFS. Tautulli has a single writer (its
  own process), so SQLite-over-NFS is in its safe regime; the existing
  NFS mount options (`soft,timeo=150,retrans=5`) match sonarr/radarr
  posture.
- Initial deploy state: `tautulli-exporter` pod CrashLoops until the
  operator runbook completes. This is **by design** — the alternative
  (placeholder secret in Git, deferred config) is worse than a
  CrashLoop that self-heals on a `kubectl rollout restart`.

## Links

- Design: `docs/superpowers/specs/2026-05-18-tautulli-design.md`
- PR: (filled in on creation)
- Existing complementary dashboard: PR #211 (Plex — Overview)
- Existing complementary exporter: PR #206 (`plex-exporter`)
