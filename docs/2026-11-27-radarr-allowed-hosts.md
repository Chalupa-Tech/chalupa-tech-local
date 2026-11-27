# Pin Radarr Allowed Hosts in git and send a Host header on probes

**Date:** 2026-11-27
**PR:** TBD

## What

Same fix as Sonarr ([#490](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/490),
`docs/2026-11-27-sonarr-allowed-hosts.md`), applied to
`gitops/apps/media/radarr/values.yaml`:

- Set `Radarr__Server__AllowedHosts` to
  `radarr,radarr.frame.chalupatech.com,radarr.media.svc,radarr.media.svc.cluster.local`.
- Added an `httpHeaders` `Host: radarr.frame.chalupatech.com` entry to the
  liveness, readiness and startup probes.

## Why

After a credentials reset and restart, Radarr never became Ready and
`radarr.frame.chalupatech.com` returned Traefik's `no available server`.
`/config/config.xml` had `<AllowedHosts>*.media.svc.cluster.local</AllowedHosts>`
(set from the UI, not tracked in git), so Radarr answered anything else with
`400 Bad Request - Invalid Hostname`:

- `localhost:7878/ping` → 200
- `<pod IP>` Host → 400 (kubelet probes → startup probe failed → restart loop)
- `radarr.frame.chalupatech.com` Host → 400 (ingress blocked even when Ready)

Radarr 6.x has the same `ServerOptions.AllowedHosts` override as Sonarr, so the
env var takes precedence over config.xml. The short name `radarr` is included in
case Seerr/Prowlarr were configured with it; Scraparr uses
`radarr.media.svc.cluster.local`.

## Notes

- The env var wins over the UI, so future UI edits to Allowed Hosts will not
  take effect. Change this list instead.
