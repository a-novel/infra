provider "google" {
  project = var.management_project_id
  region  = var.region
}

locals {
  root_name = "bootstrap"
}
