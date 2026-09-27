variable "project_id" {
  description = "Fresh, independently approved project; never reuse the retained synthetic storage trial."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^a-novel-gcs-proof-pgbr[0-9]{6,8}$", var.project_id))
    error_message = "Use a new a-novel-gcs-proof-pgbr<6–8 digits> disposable project."
  }
}

variable "service" {
  description = "Selected service; the storage module validates json-keys or authentication."
  type        = string
  nullable    = false
}

variable "retention_seconds" {
  description = "Human-approved synthetic-object retention; the storage module bounds it to 300–3600 seconds."
  type        = number
  nullable    = false
}

variable "cos_image" {
  description = "Independently reviewed exact COS image, not an image family."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^projects/cos-cloud/global/images/cos-[0-9]+-[0-9]+-[0-9]+-[0-9]+$", var.cos_image))
    error_message = "Select an exact cos-cloud COS image before planning the trial."
  }
}
