variable "rollout" {
  description = "JSON Keys pilot configuration after verified image promotion and host-network setup; null provisions only prerequisites."
  type = object({
    verification_image = string
    network            = string
    subnetwork         = string
  })
  default = null

  validation {
    condition     = var.rollout == null || var.service == "json-keys"
    error_message = "The reviewed Cloud Deploy verifier supports only the JSON Keys pilot."
  }

  validation {
    condition = var.rollout == null ? true : can(regex(
      "^${var.region}-docker\\.pkg\\.dev/${var.project_id}/agora-tooling/[a-z0-9/_-]+@sha256:[a-f0-9]{64}$",
      var.rollout.verification_image,
    ))
    error_message = "Use the reviewed verifier digest in this service's separate tooling repository."
  }
}

module "rollout" {
  source   = "../../modules/cloud-run-rollout"
  for_each = var.rollout == null ? {} : { api = var.rollout }

  project_id                 = var.project_id
  foundation_service_account = local.foundation_service_account
  region                     = var.region
  name                       = "agora-json-keys-grpc"
  runtime_service_account    = local.runtime.service_account
  notification_channels      = local.runtime.notification_channels
  artifact_bucket            = "${var.project_id}-rollout-artifacts"
  receipt_bucket             = "${trimsuffix(var.state_bucket, "-tofu-state")}-deployment-receipts"
  verification_image         = each.value.verification_image
  probe = {
    network    = each.value.network
    subnetwork = each.value.subnetwork
  }

  depends_on = [google_artifact_registry_repository.images]
}
