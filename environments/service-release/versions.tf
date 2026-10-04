terraform {
  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.0"

  backend "gcs" {
    bucket = var.state_bucket
    prefix = var.zone == null ? "services/${var.project_id}/release/" : "workloads/production/${var.zone}/${var.project_id}/${var.service}/release/"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.5.0"
    }
  }
}
