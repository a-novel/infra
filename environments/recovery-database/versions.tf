terraform {
  backend "gcs" {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "recovery-database/${var.recovery.project}"
  }

  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.10.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.4.0"
    }
    # Its decode_tfvars reads production's committed inputs.
    terraform = {
      source = "terraform.io/builtin/terraform"
    }
  }
}
