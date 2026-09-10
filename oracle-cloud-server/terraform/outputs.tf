output "public_ip" {
  description = "Public IP players connect to (port 2456/UDP)"
  value       = oci_core_instance.oracle_server.public_ip
}
