# OpenBao policy: renovate-read
#
# Grants read on the KV v2 paths used by the self-hosted Renovate bot in
# the `renovate` Kubernetes namespace (GitHub App credentials for the
# renovate-github-app ExternalSecret). Bound to the `external-secrets`
# Kubernetes auth role alongside `cloudflare-read`, `media-read`, and
# `observability-read`.
#
# Apply with `./scripts/openbao/apply-policy.sh renovate-read`, then bind:
#   bao write auth/kubernetes/role/external-secrets \
#     ... token_policies="cloudflare-read,media-read,observability-read,renovate-read"
#
# This file is the source of truth — `bao policy read renovate-read` should
# match it byte-for-byte after a successful apply.

path "secret/data/renovate/*" { capabilities = ["read"] }
