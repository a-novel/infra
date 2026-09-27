variable "project_id" {
  description = "Existing disposable storage-trial project, independently approved by the operator."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^a-novel-gcs-proof-[a-z0-9]{6,12}$", var.project_id))
    error_message = "Use a dedicated a-novel-gcs-proof-<suffix> project, never a production project."
  }
}

variable "service" {
  description = "Service whose prospective backup custody is being evaluated."
  type        = string
  nullable    = false
  validation {
    condition     = contains(["json-keys", "authentication"], var.service)
    error_message = "Select json-keys or authentication."
  }
}

variable "retention_seconds" {
  description = "Explicitly approved short retention for synthetic objects; the trial policy remains unlocked."
  type        = number
  nullable    = false
  validation {
    condition     = var.retention_seconds >= 300 && var.retention_seconds <= 3600 && floor(var.retention_seconds) == var.retention_seconds
    error_message = "Approve an integer between 300 and 3600 seconds for this disposable trial."
  }
}
