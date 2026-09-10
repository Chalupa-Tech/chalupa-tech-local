terraform {
  required_version = ">= 1.9.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
  }

  # OCI Object Storage via its S3-compatible API. Region + endpoint differ
  # per tenancy, so they arrive via -backend-config=backend.hcl (CI writes
  # it from secrets); credentials arrive via AWS_ACCESS_KEY_ID /
  # AWS_SECRET_ACCESS_KEY (OCI "customer secret keys").
  backend "s3" {
    bucket                      = "terraform-state"
    key                         = "oracle-cloud-server/terraform.tfstate"
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
