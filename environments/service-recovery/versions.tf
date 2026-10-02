terraform {
  backend "gcs" {
    bucket = var.state_bucket
    prefix = "foundation/recovery/services/${var.recovery.project}"
  }

  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.5.0"
    }
  }
}
