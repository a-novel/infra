terraform {
  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.12.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.2.0"
    }
  }
}

provider "google" {
  project = var.project_id
}
