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
resource "oci_identity_user" "openbao_unseal" {
  compartment_id = var.tenancy_ocid
  name           = "openbao-unseal"
  description    = "API-key principal used by the home OpenBao cluster to auto-unseal with the openbao-unseal key"
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

# The public half of the API key pair the owner generates locally (private
# half goes straight into the Kubernetes secret, never into Terraform state):
#   openssl genrsa -out openbao-unseal.pem 2048
#   openssl rsa -in openbao-unseal.pem -pubout -out files/openbao-unseal-api-key.pub
# Created only once the file is committed, so the rest of the stack applies
# before that step.
locals {
  openbao_unseal_pub_path = "${path.module}/files/openbao-unseal-api-key.pub"
  openbao_unseal_pub      = fileexists(local.openbao_unseal_pub_path) ? file(local.openbao_unseal_pub_path) : ""
}

resource "oci_identity_api_key" "openbao_unseal" {
  count     = local.openbao_unseal_pub != "" ? 1 : 0
  user_id   = oci_identity_user.openbao_unseal.id
  key_value = local.openbao_unseal_pub
}

# `use keys` covers Encrypt/Decrypt on the crypto endpoint and GetKey on the
# management endpoint (the wrapper reads the current key version); the
# `where` clause pins it to this one key.
resource "oci_identity_policy" "openbao_unseal" {
  compartment_id = var.compartment_ocid
  name           = "openbao-unseal"
  description    = "Let the openbao-unseal group use the openbao-unseal KMS key (OpenBao auto-unseal)"
  statements = [
    "Allow group ${oci_identity_group.openbao_unseal.name} to use keys in compartment id ${var.compartment_ocid} where target.key.id = '${oci_kms_key.openbao_unseal.id}'",
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

output "openbao_unseal_user_ocid" {
  description = "OCID of the openbao-unseal IAM user (`user=` in the OCI SDK config)"
  value       = oci_identity_user.openbao_unseal.id
}

output "openbao_unseal_api_key_fingerprint" {
  description = "Fingerprint of the registered API key (`fingerprint=` in the OCI SDK config); empty until files/openbao-unseal-api-key.pub is committed"
  value       = try(oci_identity_api_key.openbao_unseal[0].fingerprint, "")
}
