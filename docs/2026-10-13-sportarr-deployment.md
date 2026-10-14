# Sportarr deployment (media stack)

**Date:** 2026-10-13
**PRs:** #383 (app + arrs-pg), #384 (scraparr wiring, follow-up)
**Plan:** docs/superpowers/plans/2026-10-13-sportarr.md
**Handoff/spec:** docs/superpowers/handoffs/2026-10-08-sportarr-handoff.md

## What

[Sportarr](https://github.com/Sportarr/Sportarr) (sports PVR —
Sonarr/Radarr for sports events) deployed at
`gitops/apps/media/sportarr/`, auto-discovered by the `media-apps`
ApplicationSet. New `Sports/` library subPath on the `media-plexmedia`
NFS share. Postgres on the shared `arrs-pg` CNPG cluster. Metrics via
scraparr's native `sportarr` connector (follow-up PR).

## Decisions and why

- **Postgres, single database.** Sportarr is an EF Core rewrite, not
  Sonarr-v4 lineage: env vars are `Sportarr__Database__{Provider,Host,
  Port,Name,Username,Password}`, one DB (no main/log split — the
  arrs-pg wiring follows the seerr single-DB pattern, not radarr's).
  Upstream supports Postgres for **fresh installs only** (no SQLite→PG
  migration), which this is — deciding PG now avoids SQLite-on-NFS
  locking risk and a painful later migration.
- **Two PRs.** The `scraparr-apikeys` ExternalSecret has all keys
  mandatory; a sportarr entry merged before the API key exists in
  OpenBao wedges scraparr's deploy. App ships first; scraparr wiring
  merges after the real key is seeded at `scraparr/sportarr-api-key`.
- **Pre-merge seed for PR 1**: same mandatory-keys logic applies to
  `postgres/sportarr` — seeded before merging the app PR.
- **app-template 5.3.0** (current radarr pin; the 2026-10-08 handoff
  said 4.4.0 but Renovate had bumped it).
- **Prowlarr integration as a "Sonarr" app** (manual step): Prowlarr
  has no native Sportarr type yet; Sportarr serves a frozen Sonarr-v3
  API shim at `/api/v3/*` for exactly this. Revisit when Prowlarr
  ships the native type.
- **No vmalert change**: `arrs.yaml` alerts on `scraparr_services_up`
  generically by `alias` label; sportarr is covered once scraped.
- **No OpenBao policy change**: `media-read.hcl` already covers
  `secret/data/postgres/*` and `secret/data/scraparr/*`.

## Manual steps

See the plan's "Manual steps" section (mirrors the handoff): OpenBao
seeding, Sportarr UI setup, Prowlarr (as Sonarr type), NZBGet client,
scraparr key, Plex `Sports` library.
