#!/usr/bin/env bash
# Tests for scripts/plan-guard.sh: it reads a `terraform show -json` plan and
# fails when the plan would (a) delete or replace the OpenBao KMS key, vault
# or API key, or (b) create/update a billable Key Management resource.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
guard="$here/../scripts/plan-guard.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# plan <name> <json-array-of-resource_changes>
plan() { printf '{"format_version":"1.2","resource_changes":%s}\n' "$2" > "$tmp/$1.json"; echo "$tmp/$1.json"; }
rc() { local a; a=$1; shift; printf '{"address":"%s","type":"%s","change":{"actions":%s,"after":%s}}' "$a" "$1" "$2" "${3:-null}"; }

key_ok=$(rc oci_kms_key.openbao_unseal oci_kms_key '["create"]' '{"protection_mode":"SOFTWARE","key_shape":[{"algorithm":"AES","length":32}]}')
vault_ok=$(rc oci_kms_vault.openbao oci_kms_vault '["create"]' '{"vault_type":"DEFAULT"}')
apikey_ok=$(rc 'oci_identity_api_key.openbao_unseal' oci_identity_api_key '["create"]' '{}')
noop=$(rc oci_core_instance.oracle_server oci_core_instance '["no-op"]' '{}')
instance_update=$(rc oci_core_instance.oracle_server oci_core_instance '["update"]' '{"shape":"VM.Standard.A1.Flex"}')

run() { set +e; bash "$guard" "$1" > "$tmp/out" 2>&1; local r=$?; set -e; return $r; }

passes_on_free_create_and_unrelated_changes() {
  f=$(plan ok "[$key_ok,$vault_ok,$apikey_ok,$noop,$instance_update]")
  run "$f" || fail "ok plan rejected: $(cat "$tmp/out")"
  grep -q 'plan-guard: ok' "$tmp/out" || fail "ok plan: no ok line: $(cat "$tmp/out")"
}
passes_on_empty_plan() {
  f=$(plan empty '[]'); run "$f" || fail "empty plan rejected: $(cat "$tmp/out")"
}
rejects_key_delete() {
  f=$(plan del "[$(rc oci_kms_key.openbao_unseal oci_kms_key '["delete"]' null)]")
  rc=0; run "$f" || rc=$?; [ $rc -ne 0 ] || fail "key delete accepted"
  grep -q 'oci_kms_key.openbao_unseal' "$tmp/out" || fail "key delete: address not named: $(cat "$tmp/out")"
}
rejects_vault_replace() {
  f=$(plan repl "[$(rc oci_kms_vault.openbao oci_kms_vault '["delete","create"]' '{"vault_type":"DEFAULT"}')]")
  rc=0; run "$f" || rc=$?; [ $rc -ne 0 ] || fail "vault replace accepted"
}
rejects_api_key_delete() {
  f=$(plan apidel "[$(rc 'oci_identity_api_key.openbao_unseal' oci_identity_api_key '["delete"]' null)]")
  rc=0; run "$f" || rc=$?; [ $rc -ne 0 ] || fail "api key delete accepted"
}
rejects_hsm_key_and_missing_protection_mode() {
  f=$(plan hsm "[$(rc oci_kms_key.other oci_kms_key '["create"]' '{"protection_mode":"HSM"}')]")
  rc=0; run "$f" || rc=$?; [ $rc -ne 0 ] || fail "HSM key accepted"
  grep -qi 'HSM\|protection_mode' "$tmp/out" || fail "hsm: reason missing: $(cat "$tmp/out")"
  f=$(plan nomode "[$(rc oci_kms_key.other oci_kms_key '["create"]' '{"key_shape":[]}')]")
  rc=0; run "$f" || rc=$?; [ $rc -ne 0 ] || fail "key without protection_mode accepted (API default is HSM)"
}
rejects_virtual_private_vault_and_hsm_resources() {
  f=$(plan vpv "[$(rc oci_kms_vault.other oci_kms_vault '["create"]' '{"vault_type":"VIRTUAL_PRIVATE"}')]")
  rc=0; run "$f" || rc=$?; [ $rc -ne 0 ] || fail "virtual private vault accepted"
  f=$(plan hsmres "[$(rc oci_kms_hsm_cluster.x oci_kms_hsm_cluster '["create"]' '{}')]")
  rc=0; run "$f" || rc=$?; [ $rc -ne 0 ] || fail "hsm cluster accepted"
}
allows_software_key_rotation_version() {
  f=$(plan rot "[$(rc oci_kms_key_version.v2 oci_kms_key_version '["create"]' '{}')]")
  run "$f" || fail "software key version rejected: $(cat "$tmp/out")"
}
rejects_unreadable_plan() {
  echo 'not json' > "$tmp/bad.json"; rc=0; run "$tmp/bad.json" || rc=$?; [ $rc -ne 0 ] || fail "bad json accepted"
}

for t in passes_on_free_create_and_unrelated_changes passes_on_empty_plan rejects_key_delete rejects_vault_replace rejects_api_key_delete rejects_hsm_key_and_missing_protection_mode rejects_virtual_private_vault_and_hsm_resources allows_software_key_rotation_version rejects_unreadable_plan; do
  $t; echo "ok $t"
done
echo PASS
