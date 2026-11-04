# Off-box copy of the Valheim world backups (spec §5.1 item 7). The instance
# syncs /opt/valheim/backups into this bucket with rclone using instance
# principal auth, so no credentials live on the box. Objects expire after
# 30 days (the box itself keeps the newest 14 archives).

data "oci_objectstorage_namespace" "tenancy" {
  compartment_id = var.tenancy_ocid
}

resource "oci_objectstorage_bucket" "valheim_backups" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.tenancy.namespace
  name           = var.backup_bucket_name
  access_type    = "NoPublicAccess"
  versioning     = "Disabled"
}

# Object Storage needs explicit permission to run lifecycle rules.
resource "oci_identity_policy" "objectstorage_lifecycle" {
  compartment_id = var.compartment_ocid
  name           = "valheim-backups-lifecycle"
  description    = "Let the Object Storage service apply lifecycle rules to the valheim-backups bucket"
  statements = [
    "Allow service objectstorage-${var.region} to manage object-family in compartment id ${var.compartment_ocid}",
  ]
}

resource "oci_objectstorage_object_lifecycle_policy" "valheim_backups" {
  namespace = data.oci_objectstorage_namespace.tenancy.namespace
  bucket    = oci_objectstorage_bucket.valheim_backups.name

  rules {
    name        = "expire-after-30-days"
    action      = "DELETE"
    is_enabled  = true
    target      = "objects"
    time_amount = 30
    time_unit   = "DAYS"
  }

  depends_on = [oci_identity_policy.objectstorage_lifecycle]
}

resource "oci_identity_dynamic_group" "valheim_server" {
  compartment_id = var.tenancy_ocid
  name           = "valheim-server"
  description    = "The oracle-server instance (for instance-principal access to its backup bucket)"
  matching_rule  = "instance.id = '${oci_core_instance.oracle_server.id}'"
}

resource "oci_identity_policy" "valheim_backups" {
  compartment_id = var.compartment_ocid
  name           = "valheim-server-backups"
  description    = "Allow the oracle-server instance to sync world backups into the valheim-backups bucket"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.valheim_server.name} to read buckets in compartment id ${var.compartment_ocid} where target.bucket.name='${var.backup_bucket_name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.valheim_server.name} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name='${var.backup_bucket_name}'",
  ]
}
