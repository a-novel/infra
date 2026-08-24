terraform {
  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.12.6"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "= 7.45.0"
    }
  }
}
