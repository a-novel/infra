provider "google" {
  project = var.management_project_id
}

locals {
  # Pull requests plan with the read-only Plan App, whose key is the only one bootstrap lets the plan
  # identity read. Only a deploy reads the Deploy App's.
  app = var.writer ? "deploy" : "plan"
}

# An ephemeral read keeps each key out of the state and the plan.
ephemeral "google_secret_manager_secret_version" "app_key" {
  for_each = var.apps

  project = var.management_project_id
  secret  = "production-github-${local.app}-key-${each.key}"
  version = each.value[local.app].key_version
}

provider "github" {
  alias    = "organization"
  for_each = var.apps

  owner = each.key

  app_auth {
    id              = each.value[local.app].id
    installation_id = each.value[local.app].installation_id
    pem_file        = ephemeral.google_secret_manager_secret_version.app_key[each.key].secret_data
  }
}
