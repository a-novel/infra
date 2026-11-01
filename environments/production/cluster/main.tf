data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "foundation"
  }
}

locals {
  cluster = data.terraform_remote_state.foundation.outputs.cluster
  # Each service's own root pins its releases and secret versions and holds its settings. This root
  # reads it once per namespace.
  service_inputs = { for service in var.namespaces : service => provider::terraform::decode_tfvars(file("${path.module}/../${service}/terraform.tfvars")) }
}

# An ephemeral read keeps CI's access token out of the state and the plan.
ephemeral "google_client_config" "ci" {}

# CI reaches the control plane only through its DNS endpoint, whose certificate a public authority
# signs, as its own identity: the plan identity reads every object but Secrets, and the deploy
# identity applies.
provider "kubernetes" {
  host  = "https://${local.cluster.dns_endpoint}"
  token = ephemeral.google_client_config.ci.access_token
  # GKE annotates Services for its load balancers' network endpoint groups, and the Gateway's
  # controller annotates the platforms'. Removing them would detach the load balancer's backends.
  ignore_annotations = ["^cloud\\.google\\.com/neg"]
}

# Helm records each release in its namespace. ConfigMaps keep those records readable by the plan
# identity, which never reads Secrets, and no release's values hold a secret.
provider "helm" {
  helm_driver = "configmap"

  kubernetes = {
    host  = "https://${local.cluster.dns_endpoint}"
    token = ephemeral.google_client_config.ci.access_token
  }
}

# Each service's workloads, database and secrets live in its own namespace. Deleting one deletes
# everything in it, its database's volumes included.
resource "kubernetes_namespace_v1" "service" {
  for_each = var.namespaces

  metadata {
    name   = each.key
    labels = local.pod_security
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "api_endpoint" {
  description = "The control plane's DNS endpoint, which the deploy's admission check calls."
  value       = local.cluster.dns_endpoint
}
