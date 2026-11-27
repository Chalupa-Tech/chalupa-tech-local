# Pin Sonarr Allowed Hosts in git and send a Host header on probes

**Date:** 2026-11-27
**PR:** [#490](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/490)

## What

In `gitops/apps/media/sonarr/values.yaml`:

- Set `Sonarr__Server__AllowedHosts` to
  `sonarr.frame.chalupatech.com,sonarr.media.svc,sonarr.media.svc.cluster.local`.
- Added an `httpHeaders` `Host: sonarr.frame.chalupatech.com` entry to the
  liveness, readiness and startup probes.

## Why

Sonarr had been crash-looping for 5 days (690 restarts), which also broke
Seerr's Sonarr integration (`Unable to get queue from Sonarr server`) and kept
Scraparr stuck in `Init:Error`.

`/config/config.xml` had `<AllowedHosts>sonarr.frame.chalupatech.com</AllowedHosts>`,
set from the Sonarr UI and not tracked in git. Sonarr answers any other Host
header with `400 Bad Request - Invalid Hostname`. Kubelet probes `/ping` using
the pod IP, so every probe got a 400:

- `localhost:8989/ping` → 200
- `<pod IP>:8989/ping` → 400 Invalid Hostname
- `<pod IP>:8989/ping` with `Host: sonarr.frame.chalupatech.com` → 200

Because the pod was never Ready, the Service had no endpoints, so even the
allowed ingress hostname failed.

`Sonarr__Server__AllowedHosts` overrides the config.xml value
(`ConfigFileProvider.AllowedHosts => _serverOptions.AllowedHosts ?? GetValue(...)`
in v4.0.20). The list is split on `,`/`;` and the port is ignored. Both service
names are included: Scraparr calls `sonarr.media.svc.cluster.local:8989`.

## Notes

- The env var wins over whatever is set in the UI, so future UI edits to
  Allowed Hosts will not take effect. Change this list instead.
- Radarr, Lidarr and Prowlarr share this Servarr codebase. If one starts failing
  probes with 400, check for the same setting.
