provider "google" {
  project = var.workload_project_id
  region  = var.region

  default_labels = {
    application = "agora"
    environment = "production"
    managed-by  = "opentofu"
    plane       = "release"
  }
}

locals {
  root_name = "release"
}
