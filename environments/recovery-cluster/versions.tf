terraform {
  backend "gcs" {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "recovery-cluster/${var.recovery.project}"
  }

  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.9.0"
    }
  }
}
