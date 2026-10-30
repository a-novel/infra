# Each repository takes its class's settings, then its own overrides, field by field.
locals {
  defaults = {
    is_template                 = false
    has_issues                  = true
    has_wiki                    = false
    has_projects                = true
    has_discussions             = true
    allow_squash_merge          = true
    allow_merge_commit          = false
    allow_rebase_merge          = false
    allow_auto_merge            = true
    delete_branch_on_merge      = true
    allow_update_branch         = true
    web_commit_signoff_required = true
    secret_scanning             = true
    push_protection             = true
    vulnerability_alerts        = true
    dependabot_security_updates = false
    pages                       = false
    template                    = null
    tags_ruleset                = true
    admins_only                 = false
  }

  classes = {
    service   = { pages = true, template = "a-novel/service-template" }
    platform  = { pages = true, template = "a-novel/platform-template" }
    infra     = { has_discussions = false, tags_ruleset = false, admins_only = true }
    library   = { dependabot_security_updates = true }
    workflows = { dependabot_security_updates = true }
    meta      = {}
  }

  # Each tier team gets Write on its organization's bot-comment dispatcher, so any member can post
  # bot comments.
  dispatchers = ["a-novel/.github", "a-novel-kit/stack"]

  repositories = {
    for full_name, repository in var.repositories : full_name => merge(
      local.defaults,
      local.classes[repository.class],
      { for setting, value in repository.overrides : setting => value if value != null },
      {
        owner        = split("/", full_name)[0]
        name         = split("/", full_name)[1]
        class        = repository.class
        description  = repository.description
        homepage_url = repository.homepage_url
        topics       = repository.topics
        dispatcher   = contains(local.dispatchers, full_name)
      },
    )
  }

  owned = { for owner in keys(var.apps) : owner => { for repository in values(local.repositories) : repository.name => repository if repository.owner == owner } }
}

# One call per organization, each with its own App's provider. To drop an organization, remove its
# call first and its provider one apply later: a provider must outlive its resources by one apply.
module "a_novel" {
  source = "../../../modules/github-organization"

  providers = {
    github = github.a_novel
  }

  repositories       = local.owned["a-novel"]
  tiers              = var.tiers
  admin_team         = "core"
  labels             = var.labels
  bots               = var.organizations["a-novel"].bots
  scoped_secrets     = var.organizations["a-novel"].scoped_secrets
  governance_secrets = var.organizations["a-novel"].governance_secrets
}

module "a_novel_kit" {
  source = "../../../modules/github-organization"

  providers = {
    github = github.a_novel_kit
  }

  repositories       = local.owned["a-novel-kit"]
  tiers              = var.tiers
  admin_team         = "core"
  labels             = var.labels
  bots               = var.organizations["a-novel-kit"].bots
  scoped_secrets     = var.organizations["a-novel-kit"].scoped_secrets
  governance_secrets = var.organizations["a-novel-kit"].governance_secrets
}
