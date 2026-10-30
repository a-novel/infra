variable "management_project_id" {
  description = "Management project ID, which holds the GitHub App keys."
  type        = string
}

variable "apps" {
  description = "Each organization's Plan App and Deploy App: the App ID, its installation in the organization, and the pinned version of its key's secret."
  type = map(object({
    plan   = object({ id = number, installation_id = number, key_version = number })
    deploy = object({ id = number, installation_id = number, key_version = number })
  }))

  validation {
    condition     = alltrue(flatten([for apps in values(var.apps) : [for app in values(apps) : app.id > 0 && app.installation_id > 0 && app.key_version > 0]]))
    error_message = "Each App needs its ID, its installation ID and a key version, which core records when it creates the App (a-novel/.github#535)."
  }
}

variable "writer" {
  description = "Whether the run applies. The tofu action sets it, and only a deploy reads the Deploy App's key."
  type        = bool
  default     = false
}

variable "repositories" {
  description = "Every repository of the organizations, keyed \"<owner>/<name>\": its class, its metadata, and the class settings it overrides."
  type = map(object({
    class        = string
    description  = optional(string)
    homepage_url = optional(string)
    topics       = optional(list(string), [])
    overrides = optional(object({
      is_template                 = optional(bool)
      has_discussions             = optional(bool)
      pages                       = optional(bool)
      dependabot_security_updates = optional(bool)
    }), {})
  }))

  validation {
    condition     = alltrue([for name, repository in var.repositories : contains(["service", "platform", "infra", "library", "workflows", "meta"], repository.class) && contains(keys(var.apps), split("/", name)[0])])
    error_message = "Each repository needs a known class, and an organization with Apps."
  }
}

variable "organizations" {
  description = "Each organization's bot App IDs, its scoped organization secrets, and its privileged governance secrets with the Secret Manager version each repository receives."
  type = map(object({
    bots               = object({ agent = number, dependencies = number, release = number })
    scoped_secrets     = set(string)
    governance_secrets = map(number)
  }))
}

variable "tiers" {
  description = "Each contributor tier's team and the role its area teams hold on their class's repositories."
  type        = map(string)
}

variable "labels" {
  description = "The labels every repository carries, by name."
  type = map(object({
    color       = string
    description = string
  }))
}

variable "adopt" {
  description = "Whether the plan imports the live objects. Mocked providers cannot import, so the tests turn it off."
  type        = bool
  default     = true
}
