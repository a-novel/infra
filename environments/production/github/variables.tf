variable "management_project_id" {
  description = "Management project ID, which holds the GitHub App keys."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.management_project_id))
    error_message = "The management project ID must be a valid 6-30 character Google Cloud project ID."
  }
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

variable "dedicated_apps" {
  description = "By repository, as <owner>/<name>, the Agent and Dependencies Apps installed on that repository alone (a-novel/.github#560): their IDs, client IDs and logins, and the pinned version of the key each one's secret holds."
  type = map(object({
    agent        = object({ id = number, client_id = string, login = string, key_version = number })
    dependencies = object({ id = number, client_id = string, login = string, key_version = number })
  }))
  default = {}

  validation {
    condition     = alltrue(flatten([for apps in values(var.dedicated_apps) : [for app in values(apps) : app.id > 0 && app.key_version > 0 && endswith(app.login, "[bot]")]]))
    error_message = "Each dedicated App needs its ID, its login as <slug>[bot] and a key version, which core records when it creates the App."
  }
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
