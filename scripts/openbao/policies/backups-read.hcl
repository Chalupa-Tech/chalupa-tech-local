# OpenBao policy: backups-read
#
# Read access to the KV v2 paths the backup stack consumes through ESO:
#   secret/backups/restic   (property `password`) — restic repository password
#     used by every VolSync ReplicationSource secret (platform/pvc-backups).
# Bound to the `external-secrets` Kubernetes auth role alongside the other
# *-read policies (see scripts/openbao/README.md). Seed the value once with
#   OPENBAO_TOKEN=... ./scripts/openbao/kv-put.sh backups/restic password=<random-64>
# and keep a copy in 1Password: without it the restic repositories are unreadable.

path "secret/data/backups/*" { capabilities = ["read"] }
