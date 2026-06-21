# OpenBao policy: media-read
#
# Grants read on the KV v2 paths used by apps in the `media` Kubernetes
# namespace. Bound to the `external-secrets` Kubernetes auth role
# alongside `cloudflare-read` and `observability-read`.
#
# When a new media app needs a Bao-sourced secret:
#   1. Add a `path "secret/data/<app>/*" { capabilities = ["read"] }` line below.
#   2. Apply with `./scripts/openbao/apply-policy.sh media-read`.
#   3. Commit the .hcl change in the same PR as the new app's ExternalSecret.
#
# This file is the source of truth — `bao policy read media-read` should
# match it byte-for-byte after a successful apply. Drift means the file
# wasn't applied; re-run apply-policy.sh.

path "secret/data/nzbget/*"    { capabilities = ["read"] }
path "secret/data/sonarr/*"    { capabilities = ["read"] }
path "secret/data/radarr/*"    { capabilities = ["read"] }
path "secret/data/seerr/*"     { capabilities = ["read"] }
path "secret/data/tdarr/*"     { capabilities = ["read"] }
path "secret/data/postgres/*"  { capabilities = ["read"] }
path "secret/data/scraparr/*"  { capabilities = ["read"] }
path "secret/data/plex/*"      { capabilities = ["read"] }
path "secret/data/tautulli/*"  { capabilities = ["read"] }
path "secret/data/readmebook/*" { capabilities = ["read"] }
