variable "adopt_existing_jobs" {
  description = "Import the selected private service's existing jobs after their previous state owner has forgotten them."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = !var.adopt_existing_jobs || (var.zone == "private" && var.api == null)
    error_message = "Job adoption is restricted to the selected private service with no API deployment."
  }
}

import {
  for_each = var.adopt_existing_jobs ? local.jobs : {}
  to       = google_cloud_run_v2_job.application[each.key]
  id       = "projects/${var.project_id}/locations/${var.region}/jobs/agora-${var.service}-${each.key}"
}
