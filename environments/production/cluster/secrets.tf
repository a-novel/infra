locals {
  # Each secret at the version its service's root pins for Cloud Run today. This root pins the
  # add-ons' own.
  secret_versions = merge(var.addon_secret_versions, { for service in setintersection(keys(var.secrets), var.namespaces) : service => local.service_inputs[service].secret_versions })
  secret_grants = { for grant in flatten([for service, env in var.secrets : [for name in distinct(values(env)) : { service = service, name = name }]]) :
    "${grant.service}/${grant.name}" => grant
  }
}

data "google_project" "workload" {
  project_id = data.terraform_remote_state.foundation.outputs.workload_project_id
}

# External Secrets reads each namespace's secrets as that namespace's own identity, which IAM lets
# read only its service's secrets.
resource "kubernetes_service_account_v1" "secrets" {
  for_each = var.secrets

  metadata {
    name      = "secrets"
    namespace = local.namespace[each.key]
  }
}

resource "google_secret_manager_secret_iam_member" "secrets" {
  for_each = local.secret_grants

  project   = local.management_project
  secret_id = "production-${each.value.service}-${each.value.name}"
  role      = "roles/secretmanager.secretAccessor"
  member    = "principal://iam.googleapis.com/projects/${data.google_project.workload.number}/locations/global/workloadIdentityPools/${data.google_project.workload.project_id}.svc.id.goog/subject/ns/${each.value.service}/sa/${kubernetes_service_account_v1.secrets[each.value.service].metadata[0].name}"
}

# The secrets live in management, apart from the cluster's project, so the store names both.
resource "kubernetes_manifest" "secret_store" {
  for_each = var.custom_resources ? var.secrets : {}

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata   = { name = "secret-manager", namespace = local.namespace[each.key] }
    spec = {
      provider = {
        gcpsm = {
          projectID = local.management_project
          auth = {
            workloadIdentity = {
              clusterProjectID  = data.google_project.workload.project_id
              clusterLocation   = local.cluster.location
              clusterName       = local.cluster.name
              serviceAccountRef = { name = kubernetes_service_account_v1.secrets[each.key].metadata[0].name }
            }
          }
        }
      }
    }
  }
}

# The workloads read their secrets from the namespace's `secrets` Secret.
resource "kubernetes_manifest" "secrets" {
  for_each = var.custom_resources ? var.secrets : {}

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = "secrets", namespace = local.namespace[each.key] }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { kind = "SecretStore", name = kubernetes_manifest.secret_store[each.key].manifest.metadata.name }
      target          = { name = "secrets", creationPolicy = "Owner" }
      data = [for variable, name in each.value : {
        secretKey = variable
        remoteRef = { key = "production-${each.key}-${name}", version = tostring(local.secret_versions[each.key][name]) }
      }]
    }
  }

  # A new database reads its host's password from the Secret as it starts its import.
  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.secrets]
}
