terraform {
  backend "gcs" {
    bucket = var.state_bucket
    prefix = "foundation/recovery/services/${var.recovery.project}"
  }

  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.12.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.2.0"
    }
  }
}
