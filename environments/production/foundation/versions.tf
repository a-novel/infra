terraform {
  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.1"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "8.5.0"
    }
  }
}
