#!/usr/bin/env bash
# Guard a Terraform plan (JSON from `terraform show -json tfplan`) before it
# is applied or posted. Fails (exit 1) when the plan would:
#   1. delete or replace the OpenBao seal dependencies — the KMS key, its
#      vault, or the openbao-unseal API key (losing the key makes every raft
#      snapshot unreadable; docs/2026-11-05-openbao-auto-unseal.md);
#   2. create/update a billable Key Management resource: an HSM-protected
#      key (also the API default when protection_mode is omitted), a
#      VIRTUAL_PRIVATE vault, or any HSM/external-KMS resource.
# Software key versions (rotation) stay allowed: they are free.
set -euo pipefail
plan=${1:?usage: plan-guard.sh <plan.json>}
jq -e '.resource_changes? // empty | type == "array"' "$plan" >/dev/null 2>&1 || { echo "plan-guard: cannot read resource_changes from $plan" >&2; exit 1; }

violations=$(jq -r '
  def acts: .change.actions;
  def has($a): acts | index($a) != null;
  .resource_changes[]
  | ( select((.type == "oci_kms_key" or .type == "oci_kms_vault" or .type == "oci_identity_api_key") and has("delete"))
      | "\(.address): plan \(acts | join("+"))s a seal dependency (never delete/replace it; see docs/runbooks/openbao-seal-migration.md)" ),
    ( select(.type == "oci_kms_key" and (has("create") or has("update")) and ((.change.after.protection_mode // "") != "SOFTWARE"))
      | "\(.address): protection_mode is \(.change.after.protection_mode // "unset (API default HSM)") — only SOFTWARE keys are free" ),
    ( select(.type == "oci_kms_vault" and (has("create") or has("update")) and ((.change.after.vault_type // "") != "DEFAULT"))
      | "\(.address): vault_type is \(.change.after.vault_type // "unset") — only DEFAULT vaults are free" ),
    ( select((.type | test("^oci_kms_(hsm|ekms)")) and (has("create") or has("update")))
      | "\(.address): \(.type) is a billable Key Management resource" )
' "$plan")

if [ -n "$violations" ]; then
  echo "plan-guard: REFUSING this plan:" >&2
  printf '%s\n' "$violations" | sed 's/^/  - /' >&2
  exit 1
fi
changes=$(jq '[.resource_changes[] | select(.change.actions != ["no-op"])] | length' "$plan")
echo "plan-guard: ok ($changes resource change(s), no seal-dependency deletes, no billable KMS resources)"
