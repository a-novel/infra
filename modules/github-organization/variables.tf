variable "repositories" {
  description = "The organization's repositories by name, each with its class's settings and its own overrides already merged."
  type = map(object({
    class        = string
    description  = optional(string)
    homepage_url = optional(string)
    topics       = list(string)
    # The "<owner>/<name>" template a new repository starts from. An adopted repository ignores it.
    template = optional(string)
    # Whether the tier teams themselves get Write here, so any member can post bot comments.
    dispatcher = bool

    is_template                 = bool
    has_issues                  = bool
    has_wiki                    = bool
    has_projects                = bool
    has_discussions             = bool
    allow_squash_merge          = bool
    allow_merge_commit          = bool
    allow_rebase_merge          = bool
    allow_auto_merge            = bool
    delete_branch_on_merge      = bool
    allow_update_branch         = bool
    secret_scanning             = bool
    push_protection             = bool
    vulnerability_alerts        = bool
    dependabot_security_updates = bool
    pages                       = bool
    # Whether the tags and release-lines rulesets guard version tags and release lines.
    tags_ruleset = bool
    # Whether only admins bypass the rulesets: a class whose merges deploy production.
    admins_only = bool
  }))
}

variable "owner" {
  description = "The organization's login, which discovery's API paths name."
  type        = string
}

variable "bots" {
  description = "App IDs of the organization's bots: agent posts the governance checks, dependencies opens Renovate's pull requests, and release cuts releases."
  type = object({
    agent        = number
    dependencies = number
    release      = number
  })
}

variable "scoped_secrets" {
  description = "Organization secrets with selected-repository visibility, each granted to the repositories whose workflows name it. An admin switches a secret to selected visibility by hand before listing it."
  type        = set(string)
}

variable "governance_secrets" {
  description = "The privileged secrets, held only by each repository's governance environment. A repository whose workflows name one gets the environment."
  type        = set(string)
}

variable "tiers" {
  description = "Each contributor tier's team and the role its area teams hold on their class's repositories."
  type        = map(string)

  validation {
    condition     = alltrue([for permission in values(var.tiers) : contains(["pull", "triage", "push", "maintain", "admin"], permission)])
    error_message = "A tier's permission must be a built-in repository role."
  }
}

variable "admin_team" {
  description = "Slug of the team that administers every repository through its organization role, which each repository lists among its teams."
  type        = string
}

variable "labels" {
  description = "The labels every repository carries, by name. Labels outside this set are left alone: the Epic machinery, infra's gates and Dependabot create their own."
  type = map(object({
    color       = string
    description = string
  }))
}
