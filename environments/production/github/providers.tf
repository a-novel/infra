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
  alias = "a_novel"
  owner = "a-novel"

  app_auth {
    id              = var.apps["a-novel"][local.app].id
    installation_id = var.apps["a-novel"][local.app].installation_id
    pem_file        = ephemeral.google_secret_manager_secret_version.app_key["a-novel"].secret_data
  }
}

provider "github" {
  alias = "a_novel_kit"
  owner = "a-novel-kit"

  app_auth {
    id              = var.apps["a-novel-kit"][local.app].id
    installation_id = var.apps["a-novel-kit"][local.app].installation_id
    pem_file        = ephemeral.google_secret_manager_secret_version.app_key["a-novel-kit"].secret_data
  }
}
