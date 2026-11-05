# OpenBao auto-unseal (docs/2026-11-05-openbao-auto-unseal.md).
#
# The home cluster's OpenBao unseals itself with a key held in OCI Vault.
# Everything here is in OCI's free tier: a DEFAULT (shared) vault and a
# SOFTWARE-protected key cost $0. HSM-protected keys and virtual private
# vaults are billed and must never be used here. The seal is a hard
# dependency of the raft data (losing the key makes every raft snapshot
# unreadable), hence prevent_destroy on both the vault and the key.

resource "oci_kms_vault" "openbao" {
  compartment_id = var.compartment_ocid
  display_name   = "openbao-unseal"
  vault_type     = "DEFAULT"

  lifecycle {
    prevent_destroy = true
  }
}

resource "oci_kms_key" "openbao_unseal" {
  compartment_id      = var.compartment_ocid
  display_name        = "openbao-unseal"
  management_endpoint = oci_kms_vault.openbao.management_endpoint
  protection_mode     = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  lifecycle {
    prevent_destroy = true
  }
}

# A dedicated IAM user whose only credential is the API key the OpenBao pods
# hold (secret openbao-oci-kms). No console password, no auth tokens, no
# customer secret keys: the key can only drive KMS encrypt/decrypt on the
# one key the policy below names.
# Identity-domain tenancies refuse a user without a primary email
# ("IdcsConversionError: The primary email must be specified"); a plus-address
# of the budget alert mailbox keeps any notice about this principal with the
# owner without needing a second mailbox.
resource "oci_identity_user" "openbao_unseal" {
  compartment_id = var.tenancy_ocid
  name           = "openbao-unseal"
  description    = "API-key principal used by the home OpenBao cluster to auto-unseal with the openbao-unseal key"
  email          = replace(var.budget_alert_email, "@", "+openbao-unseal@")
}

resource "oci_identity_user_capabilities_management" "openbao_unseal" {
  user_id                      = oci_identity_user.openbao_unseal.id
  can_use_api_keys             = true
  can_use_auth_tokens          = false
  can_use_console_password     = false
  can_use_customer_secret_keys = false
  can_use_smtp_credentials     = false
}

resource "oci_identity_group" "openbao_unseal" {
  compartment_id = var.tenancy_ocid
  name           = "openbao-unseal"
  description    = "Principals allowed to use the openbao-unseal KMS key"
}

resource "oci_identity_user_group_membership" "openbao_unseal" {
  group_id = oci_identity_group.openbao_unseal.id
  user_id  = oci_identity_user.openbao_unseal.id
}

# The public half of the API key pair the owner generated locally (private
# half lives only in the Kubernetes secret openbao-oci-kms and 1Password):
#   openssl genrsa -out openbao-unseal.pem 2048
#   openssl rsa -in openbao-unseal.pem -pubout -out files/openbao-unseal-api-key.pub
# Replacing the file replaces the registered key (the pods then need the new
# private half); deleting it would delete the key and strand the cluster, so
# prevent_destroy — rotate by editing the file content, never by removing it.
resource "oci_identity_api_key" "openbao_unseal" {
  user_id   = oci_identity_user.openbao_unseal.id
  key_value = file("${path.module}/files/openbao-unseal-api-key.pub")

  lifecycle {
    prevent_destroy = true
  }
}

# Least privilege, pinned to this one key. `use keys` alone would also grant
# KEY_EXPORT (software keys are exportable), so a stolen API key could take a
# permanent copy of the unseal key; the `request.permission` clause limits it
# to the two operations the seal performs. `read keys` covers GetKey.
resource "oci_identity_policy" "openbao_unseal" {
  compartment_id = var.compartment_ocid
  name           = "openbao-unseal"
  description    = "Let the openbao-unseal group encrypt/decrypt with (and read) the openbao-unseal KMS key only"
  statements = [
    "Allow group ${oci_identity_group.openbao_unseal.name} to use keys in compartment id ${var.compartment_ocid} where all {target.key.id = '${oci_kms_key.openbao_unseal.id}', any {request.permission = 'KEY_ENCRYPT', request.permission = 'KEY_DECRYPT'}}",
    "Allow group ${oci_identity_group.openbao_unseal.name} to read keys in compartment id ${var.compartment_ocid} where target.key.id = '${oci_kms_key.openbao_unseal.id}'",
  ]
}

# Non-secret values that go into the openbao-oci-kms secret (runbook
# docs/runbooks/openbao-seal-migration.md).
output "openbao_kms_key_id" {
  description = "OCID of the OpenBao auto-unseal key (secret key `key_id`)"
  value       = oci_kms_key.openbao_unseal.id
}

output "openbao_kms_crypto_endpoint" {
  description = "Vault crypto endpoint (secret key `crypto_endpoint`)"
  value       = oci_kms_vault.openbao.crypto_endpoint
}

output "openbao_kms_management_endpoint" {
  description = "Vault management endpoint (secret key `management_endpoint`)"
  value       = oci_kms_vault.openbao.management_endpoint
}

# The two values that identify the auth principal are marked sensitive so
# the public Actions log does not print them; read them from the OCI console
# (Identity → Users → openbao-unseal) or compute the fingerprint locally:
#   openssl rsa -pubin -in files/openbao-unseal-api-key.pub -outform DER | openssl md5 -c
output "openbao_unseal_user_ocid" {
  description = "OCID of the openbao-unseal IAM user (`user=` in the OCI SDK config)"
  value       = oci_identity_user.openbao_unseal.id
  sensitive   = true
}

output "openbao_unseal_api_key_fingerprint" {
  description = "Fingerprint of the registered API key (`fingerprint=` in the OCI SDK config)"
  value       = oci_identity_api_key.openbao_unseal.fingerprint
  sensitive   = true
}
