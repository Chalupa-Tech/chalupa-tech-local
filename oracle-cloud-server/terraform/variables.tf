variable "tenancy_ocid" {
  type = string
}

variable "user_ocid" {
  type = string
}

variable "api_key_fingerprint" {
  type = string
}

variable "api_private_key" {
  type      = string
  sensitive = true
}

variable "region" {
  type = string
}

variable "compartment_ocid" {
  description = "Compartment for all resources; the tenancy root OCID is fine"
  type        = string
}

variable "ssh_public_key" {
  description = "Authorized key for the ubuntu user (CI's ORACLE_SSH keypair)"
  type        = string
}

variable "tailscale_auth_key" {
  description = "Pre-authorized, tagged (tag:oracle-server) Tailscale auth key"
  type        = string
  sensitive   = true
}

variable "instance_shape" {
  type    = string
  default = "VM.Standard.A1.Flex"
}

variable "instance_ocpus" {
  type    = number
  default = 4
}

variable "instance_memory_gb" {
  type    = number
  default = 24
}

variable "boot_volume_gb" {
  type    = number
  default = 150
}

variable "budget_amount" {
  description = "Monthly budget (USD) whose alert rules act as a spend tripwire; expected spend is $0"
  type        = number
  default     = 5
}

variable "budget_alert_email" {
  description = "Recipient for budget alert emails (GitHub secret OCI_BUDGET_ALERT_EMAIL)"
  type        = string
}
