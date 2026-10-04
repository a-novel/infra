terraform {
  # renovate: datasource=github-releases depName=opentofu/opentofu
  required_version = "= 1.13.1"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.5.0"
    }
  }
}

# Every resource selects its project or bucket explicitly. Use the default provider when
# standalone, or inherit the caller's provider (including its mock) when composed.
