provider "google" {
  project = var.workload_project_id
  region  = var.region
}

locals {
  root_name = "foundation"
}
