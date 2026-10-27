variable "management_project_id" {
  description = "Management project ID, which holds the Sentry token secrets."
  type        = string
}

variable "organization" {
  description = "Slug of the Sentry organization this root configures."
  type        = string
}

variable "base_url" {
  description = "Sentry API of the organization's region, such as https://sentry.io/api/ or https://de.sentry.io/api/."
  type        = string

  validation {
    condition     = can(regex("^https://([a-z]+\\.)?sentry\\.io/api/$", var.base_url))
    error_message = "Use a Sentry SaaS API URL ending in /api/."
  }
}

variable "team" {
  description = "Slug of the Sentry team that owns the projects."
  type        = string
}

variable "projects" {
  description = "Service repositories that report to Sentry. Release CI names each project after its repository."
  type        = set(string)
}

variable "token_versions" {
  description = "Numeric versions of the Sentry token secrets, by CI identity."
  type = object({
    plan   = number
    deploy = number
  })
}

variable "adopt_projects" {
  description = "Import the projects created by hand before this root. Mocked providers cannot import, so tests turn it off."
  type        = bool
  default     = true
  nullable    = false
}

variable "writer" {
  description = "Whether the run applies. The tofu action sets it, and only a deploy reads the token that writes."
  type        = bool
  default     = false
}
