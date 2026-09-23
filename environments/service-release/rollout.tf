variable "rollout" {
  description = "Optional JSON Keys API request pins, independently authorized and retained with the private plan; null keeps this root jobs-only."
  type = object({
    project_number   = string
    image            = string
    release_id       = string
    request_id       = string
    source_commit    = string
    skaffold_version = string
  })
  default = null

  validation {
    condition     = var.rollout == null ? true : var.service == "json-keys"
    error_message = "Only the JSON Keys API pilot is supported; Authentication remains jobs-only."
  }
  validation {
    condition = var.rollout == null ? true : (
      can(regex("^[1-9][0-9]*$", var.rollout.project_number)) &&
      length(local.rollout_receipt_bucket) <= 63
    )
    error_message = "Use the independently authorized numeric service project and a valid derived management receipt bucket."
  }
  validation {
    condition = var.rollout == null ? true : alltrue([
      for field, collection in { pipeline = "deliveryPipelines", target = "targets" } : try(contains([
        for project in [var.project_id, var.rollout.project_number] :
        "projects/${project}/locations/${var.region}/${collection}/agora-json-keys-grpc"
      ], local.coordinates.rollout[field]), false)
    ])
    error_message = "The approved foundation document must contain this service project's exact regional JSON Keys pipeline and target."
  }
  validation {
    condition = var.rollout == null ? true : can(regex(
      "^${var.region}-docker\\.pkg\\.dev/${var.project_id}/agora-production/service-json-keys/grpc@sha256:[a-f0-9]{64}$", var.rollout.image,
    ))
    error_message = "Pin this service project's promoted JSON Keys gRPC image by SHA-256 digest."
  }
  validation {
    condition = var.rollout == null ? true : (
      can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.rollout.release_id)) &&
      can(regex("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", var.rollout.request_id)) &&
      var.rollout.request_id != "00000000-0000-0000-0000-000000000000"
    )
    error_message = "Choose and retain one valid release ID and nonzero lowercase request UUID before planning; never generate replacements during retry."
  }
  validation {
    condition = var.rollout == null ? true : (
      can(regex("^[a-f0-9]{40}$", var.rollout.source_commit)) &&
      can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.rollout.skaffold_version))
    )
    error_message = "Pin the reviewed source commit and supported Skaffold x.y.z version."
  }
}

locals {
  management_bucket_prefix = trimsuffix(var.state_bucket, "-tofu-state")
  rollout_receipt_bucket   = "${local.management_bucket_prefix}-deployment-receipts"
  rollout_parent           = var.rollout == null ? null : "projects/${var.rollout.project_number}/locations/${var.region}/deliveryPipelines/agora-json-keys-grpc"
}

output "release_request" {
  description = "Native CreateReleaseRequest JSON for the existing submitter; configuration only, not submission intent, readiness or approval."
  sensitive   = true
  value = var.rollout == null ? null : {
    parent    = local.rollout_parent
    releaseId = var.rollout.release_id
    requestId = var.rollout.request_id
    release = {
      name = "${local.rollout_parent}/releases/${var.rollout.release_id}"
      annotations = {
        request-id    = var.rollout.request_id
        source-commit = var.rollout.source_commit
      }
      skaffoldConfigUri  = "gs://${local.rollout_receipt_bucket}/services/${var.project_id}/production/sources/${var.rollout.source_commit}.tar.gz"
      skaffoldConfigPath = "skaffold.yaml"
      skaffoldVersion    = var.rollout.skaffold_version
      buildArtifacts     = [{ image = "service-json-keys", tag = var.rollout.image }]
      deployParameters = {
        projectId               = var.project_id
        network                 = var.network.network
        subnetwork              = var.network.subnetwork
        runtimeServiceAccount   = try(local.coordinates.runtime.service_account, "")
        databasePrivateIP       = try(local.coordinates.database.private_ip, "")
        managementProjectNumber = trimprefix(local.management_bucket_prefix, "${var.management_project_id}-")
        masterKeyVersion        = tostring(lookup(var.secret_versions, "app-master-key", 0))
        postgresPasswordVersion = tostring(lookup(var.secret_versions, "postgres-password", 0))
      }
    }
  }
}
