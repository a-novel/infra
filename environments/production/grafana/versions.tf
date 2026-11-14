terraform {
  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.9"

  backend "gcs" {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "grafana"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.10.0"
    }
    # Grafana Labs' own provider covers the stack's alerting, dashboards and Frontend Observability.
    grafana = {
      source  = "grafana/grafana"
      version = "4.54.0"
    }
    # Its decode_tfvars reads foundation's node pool.
    terraform = {
      source = "terraform.io/builtin/terraform"
    }
  }
}
