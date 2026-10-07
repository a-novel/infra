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
  application_jobs = {
    authentication_migrations = { name = "agora-authentication-migrations", invocation_class = "release" }
    json_keys_migrations      = { name = "agora-json-keys-migrations", invocation_class = "release" }
    json_keys_rotate          = { name = "agora-json-keys-rotatekeys", invocation_class = "scheduled" }
  }
}
