terraform {
  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.1"

  backend "gcs" {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "bootstrap"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.5.0"
    }
  }
}
