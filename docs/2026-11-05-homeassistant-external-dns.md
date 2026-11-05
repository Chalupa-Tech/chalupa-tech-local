# 2026-11-05 — Home Assistant missing from public DNS

PR: _TBD_

## Symptom

`https://homeassistant.frame.chalupatech.com` failed to resolve on a Mac with
Tailscale MagicDNS enabled, while `grafana.frame…`, `argocd.frame…` etc.
worked. Home Assistant itself was healthy (200 through Traefik at
`192.168.1.230` and directly at `192.168.1.234:8123`).

## Cause

The Home Assistant IngressRoutes rendered their rule as
`Host("homeassistant.frame.chalupatech.com")` because the template used
`{{ .Values.homeassistant.host | quote }}`. Traefik accepts double quotes,
so routing worked, but external-dns (v0.23.0, `--source=traefik-proxy`)
extracts hostnames with a backtick-only regex
(`source/traefik_proxy.go`, `traefikHostExtractor` / `traefikValueProcessor`).
It found no hosts, logged nothing, and never created the Cloudflare A record
or its `_edns.` ownership TXT.

LAN clients using the Unifi gateway for DNS never noticed: the gateway's
local `*.frame.chalupatech.com` override answers `192.168.1.230`, and it also
intercepts plain port-53 queries to public resolvers. Clients resolving via
public DNS (e.g. Tailscale MagicDNS forwarding over DoH) got NXDOMAIN.

## Fix

Render `` Host(`{{ .Values.homeassistant.host }}`) `` in both IngressRoutes,
matching every other app. This was the only chart in the cluster using
double quotes.

## Related (no repo change)

A Tailscale split-DNS nameserver was added in the admin console:
`frame.chalupatech.com → 192.168.1.1`. Tailnet clients now get the Unifi
local overrides for `frame.chalupatech.com`, which also covers local-only
names with no public record (e.g. `truenas.frame…` → `192.168.1.40`).
Off-LAN clients need "Use Tailscale subnets" (accept-routes) enabled to reach
`192.168.1.1` via the `lxcprxtailscale` subnet router.
