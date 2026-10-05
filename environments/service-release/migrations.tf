variable "migration_image" {
  description = "Verified private migration image for a routine release; null keeps definition-only bootstrap."
  type        = string
  default     = null

  validation {
    condition = var.migration_image == null ? true : (
      (var.zone == "private" || (var.zone == "public-api" && var.service == "authentication")) &&
      can(regex("^${var.region}-docker\\.pkg\\.dev/${var.zone == "public-api" ? var.private_project_id : var.project_id}/agora-${var.service}-private-production/service-${var.service}/jobs/migrations@sha256:[a-f0-9]{64}$", var.migration_image)) &&
      (var.zone == "public-api" || var.migration_image == lookup(var.images, "migrations", ""))
    )
    error_message = "Routine releases must identify the selected family's exact private migration image."
  }
}

locals {
  migration_token = var.migration_image == null ? null : substr(sha256(var.migration_image), 0, 24)
}
