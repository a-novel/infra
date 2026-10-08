terraform {
  backend "gcs" {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "foundation/recovery/services/${var.recovery.project}"
  }

  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.1"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.5.0"
    }
  }
}
