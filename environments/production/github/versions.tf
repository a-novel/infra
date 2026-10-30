terraform {
  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.2"

  backend "gcs" {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "github"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.8.1"
    }
    github = {
      source  = "integrations/github"
      version = "6.13.0"
    }
  }
}
