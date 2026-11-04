output "public_ip" {
  description = "Public IP players connect to (port 2456/UDP)"
  value       = oci_core_instance.oracle_server.public_ip
}

output "backup_bucket" {
  description = "Object Storage bucket holding off-box Valheim world backups"
  value       = oci_objectstorage_bucket.valheim_backups.name
}

output "backup_namespace" {
  description = "Object Storage namespace (rclone.conf `namespace`)"
  value       = data.oci_objectstorage_namespace.tenancy.namespace
}
