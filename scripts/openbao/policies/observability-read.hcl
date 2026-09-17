# OpenBao policy: observability-read
#
# Grants read on the KV v2 paths used by apps in observability
# namespaces (grafana, vm-system). Bound to the `external-secrets`
# Kubernetes auth role alongside `cloudflare-read`, `media-read`, and
# `renovate-read` — the binding already exists (seed-grafana-admin.sh),
# so extending this file + apply-policy.sh is all a new path needs.
#
# Apply with: ./scripts/openbao/apply-policy.sh observability-read
#
# This file is the source of truth — `bao policy read observability-read`
# should match it byte-for-byte after a successful apply. (Until first
# apply, the live policy is the seed-grafana-admin.sh one-liner covering
# only grafana/*.)

path "secret/data/grafana/*" { capabilities = ["read"] }
path "secret/data/vmalert/*" { capabilities = ["read"] }
path "secret/data/truenas-alerts/*" { capabilities = ["read"] }
