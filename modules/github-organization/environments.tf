# The environments whose secrets only refs a ruleset guards may read: release, where every job waits
# for an admin team or the repository's owners; governance, which holds the privileged keys its
# workflows name; and sourcemaps. GitHub creates the others, github-pages and copilot among them, so
# they are left alone.
locals {
  environments = merge([
    for name in local.ready : {
      for environment in concat(
        contains(local.discovered[name].environments, "release") ? ["release"] : [],
        length(setintersection(local.discovered[name].secrets, var.governance_secrets)) > 0 ? ["governance"] : [],
        contains(local.discovered[name].environments, "sourcemaps") ? ["sourcemaps"] : [],
      ) : "${name}:${environment}" => { repository = name, environment = environment }
    }
  ]...)

  # The default branch, plus release lines and version tags where the tags ruleset limits who creates
  # them. A workflow on any other ref never unlocks an environment.
  deployment_policies = merge([
    for key, environment in local.environments : {
      for policy in concat(
        [{ type = "branch", pattern = local.default_branch }],
        var.repositories[environment.repository].tags_ruleset ? [{ type = "branch", pattern = "release/v*" }, { type = "tag", pattern = "v*" }] : [],
      ) : "${key}:${policy.type}:${policy.pattern}" => merge(environment, policy, { key = key })
    }
  ]...)
}

data "github_team" "admin" {
  slug = var.admin_team
}

resource "github_repository_environment" "this" {
  for_each = local.environments

  repository          = github_repository.this[each.value.repository].name
  environment         = each.value.environment
  can_admins_bypass   = true
  prevent_self_review = false

  # The person who dispatched a release may approve it, and no bot can.
  dynamic "reviewers" {
    for_each = each.value.environment == "release" ? [1] : []

    content {
      teams = [
        tonumber(data.github_team.admin.id),
        tonumber(github_team.area["owners-${var.repositories[each.value.repository].class}"].id),
      ]
    }
  }

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "this" {
  for_each = local.deployment_policies

  repository     = github_repository.this[each.value.repository].name
  environment    = github_repository_environment.this[each.value.key].environment
  branch_pattern = each.value.type == "branch" ? each.value.pattern : null
  tag_pattern    = each.value.type == "tag" ? each.value.pattern : null
}

# Each scoped organization secret reaches exactly the repositories whose workflows name it.
resource "github_actions_organization_secret_repositories" "this" {
  for_each = var.scoped_secrets

  secret_name             = each.key
  selected_repository_ids = sort([for name in local.ready : github_repository.this[name].repo_id if contains(local.discovered[name].secrets, each.key)])
}
