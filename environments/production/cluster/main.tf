data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "foundation"
  }
}

# An ephemeral read keeps CI's access token out of the state and the plan.
ephemeral "google_client_config" "ci" {}

# CI reaches the control plane only through its DNS endpoint, whose certificate a public authority
# signs, as its own identity: the plan identity reads every object but Secrets, and the deploy
# identity applies.
provider "kubernetes" {
  host  = "https://${data.terraform_remote_state.foundation.outputs.cluster.dns_endpoint}"
  token = ephemeral.google_client_config.ci.access_token
}

# Each service's workloads, database and secrets live in its own namespace. Deleting one deletes
# everything in it, its database's volumes included.
resource "kubernetes_namespace_v1" "service" {
  for_each = var.namespaces

  metadata {
    name = each.key
  }

  lifecycle {
    prevent_destroy = true
  }
}
