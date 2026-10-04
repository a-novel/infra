terraform {
  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.1"

  backend "gcs" {
    bucket = var.state_bucket
    prefix = var.zone == null ? "foundation/services/${var.project_id}/" : "foundation/workloads/production/${var.zone}/${var.project_id}/${var.service}/"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.5.0"
    }
  }
}
