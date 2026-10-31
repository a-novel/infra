terraform {
  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.2"

  backend "gcs" {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "cluster"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.8.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.14.2"
    }
    # Its decode_tfvars reads each service root's inputs.
    terraform = {
      source = "terraform.io/builtin/terraform"
    }
  }
}
