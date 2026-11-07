terraform {
  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.9"

  backend "gcs" {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "foundation"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.9.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "8.9.0"
    }
  }
}
