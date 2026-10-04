variable "rollout" {
  description = "Suspended API pipeline after reviewed image promotion and host-network setup; null leaves rollout unconfigured."
  type = object({
    verification_image = string
    network            = string
    subnetwork         = string
  })
  default = null

  validation {
    condition     = var.rollout == null || var.service == "json-keys" || var.zone == "public-api"
    error_message = "Select JSON Keys gRPC/REST or Authentication REST; private Authentication and the dedicated Authentication pilot are not enrolled."
  }

  validation {
    condition = var.rollout == null ? true : can(regex(
      "^${var.region}-docker\\.pkg\\.dev/${var.project_id}/${var.zone == null ? "agora-tooling" : "agora-${var.service}-${local.zone_suffix}-tooling"}/[a-z0-9/_-]+@sha256:[a-f0-9]{64}$",
      var.rollout.verification_image,
    ))
    error_message = "Use the reviewed verifier digest in this service's separate tooling repository."
  }
}

module "rollout" {
  source   = "../../modules/cloud-run-rollout"
  for_each = var.rollout == null ? {} : { api = var.rollout }

  project_id                 = var.project_id
  scope                      = var.zone == null ? null : { service = var.service, zone = var.zone }
  foundation_service_account = local.foundation_service_account
  region                     = var.region
  name                       = "agora-${var.service}-${var.zone == "public-api" ? "rest" : "grpc"}"
  runtime_service_account    = local.runtime.service_account
  notification_channels      = local.runtime.notification_channels
  artifact_bucket            = var.zone == null ? "${var.project_id}-rollout-artifacts" : "${var.project_id}-${var.service}-${local.zone_suffix}-rollout"
  receipt_bucket             = "${trimsuffix(var.state_bucket, "-tofu-state")}-deployment-receipts"
  verification_image         = each.value.verification_image
  probe = {
    network    = each.value.network
    subnetwork = each.value.subnetwork
  }

  depends_on = [google_artifact_registry_repository.images]
}
