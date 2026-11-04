# OpenBao policy: snapshot
#
# Lets the openbao-snapshot CronJob (gitops/apps/platform/openbao/templates/
# snapshot-cronjob.tpl) save raft snapshots. Bound to the `openbao-snapshot`
# Kubernetes auth role (SA openbao-snapshot, namespace openbao):
#
#   OPENBAO_TOKEN=... ./scripts/openbao/apply-policy.sh snapshot
#   kubectl -n openbao exec openbao-0 -- env BAO_TOKEN="$OPENBAO_TOKEN" \
#     bao write auth/kubernetes/role/openbao-snapshot \
#       bound_service_account_names=openbao-snapshot \
#       bound_service_account_namespaces=openbao \
#       token_policies=snapshot ttl=15m
#
# This file is the source of truth; re-apply if `bao policy read snapshot` drifts.

path "sys/storage/raft/snapshot" { capabilities = ["read"] }
