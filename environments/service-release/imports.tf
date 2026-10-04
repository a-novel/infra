variable "adopt_existing_jobs" {
  description = "Import the selected private service's existing jobs after their previous state owner has forgotten them."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = !var.adopt_existing_jobs || var.zone == "private"
    error_message = "Job adoption is restricted to the selected private service."
  }
}

variable "adopt_existing_api" {
  description = "Import the existing private JSON Keys gRPC service after its previous state owner has forgotten it."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = !var.adopt_existing_api || (var.zone == "private" && var.service == "json-keys" && var.api != null)
    error_message = "API adoption is restricted to the existing private JSON Keys gRPC service."
  }
}

import {
  for_each = var.adopt_existing_api ? toset(["json-keys"]) : toset([])
  to       = google_cloud_run_v2_service.api[0]
  id       = "projects/${var.project_id}/locations/${var.region}/services/agora-json-keys-grpc"
}

import {
  for_each = var.adopt_existing_jobs ? local.jobs : {}
  to       = google_cloud_run_v2_job.application[each.key]
  id       = "projects/${var.project_id}/locations/${var.region}/jobs/agora-${var.service}-${each.key}"
}
