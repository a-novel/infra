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
  }

  classes = {
    service   = { pages = true, template = "a-novel/service-template" }
    platform  = { pages = true, template = "a-novel/platform-template" }
    infra     = { has_discussions = false }
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
}

# The organizations with a repository, a subset of those with Apps: an organization's provider must
# outlive its resources by one apply, so dropping it takes its repositories first, then its Apps.
module "organization" {
  source   = "../../../modules/github-organization"
  for_each = toset([for repository in values(local.repositories) : repository.owner])

  providers = {
    github = github.organization[each.key]
  }

  repositories = { for repository in values(local.repositories) : repository.name => repository if repository.owner == each.key }
  tiers        = var.tiers
  admin_team   = "core"
  labels       = var.labels
}
