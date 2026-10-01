terraform {
  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.0"

  backend "gcs" {
    bucket = var.state_bucket
    prefix = "services/${var.project_id}/release/"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.5.0"
    }
  }
}
