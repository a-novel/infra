locals {
  # One area team per tier and per class this organization has a repository of.
  areas = {
    for pair in setproduct(keys(var.tiers), distinct([for repository in values(var.repositories) : repository.class])) :
    "${pair[0]}-${pair[1]}" => { tier = pair[0], class = pair[1] }
  }

  labels = {
    for pair in setproduct(keys(var.repositories), keys(var.labels)) :
    "${pair[0]}:${pair[1]}" => { repository = pair[0], name = pair[1] }
  }
}

resource "github_team" "tier" {
  for_each = var.tiers

  name    = each.key
  privacy = "closed"
}

# A member joins the area teams they work in, and the tier team's own grants reach them too.
resource "github_team" "area" {
  for_each = local.areas

  name           = each.key
  privacy        = "closed"
  parent_team_id = github_team.tier[each.value.tier].id
}

resource "github_repository" "this" {
  for_each = var.repositories

  name         = each.key
  description  = each.value.description
  homepage_url = each.value.homepage_url
  topics       = each.value.topics
  visibility   = "public"
  is_template  = each.value.is_template

  has_issues      = each.value.has_issues
  has_wiki        = each.value.has_wiki
  has_projects    = each.value.has_projects
  has_discussions = each.value.has_discussions

  allow_squash_merge     = each.value.allow_squash_merge
  allow_merge_commit     = each.value.allow_merge_commit
  allow_rebase_merge     = each.value.allow_rebase_merge
  allow_auto_merge       = each.value.allow_auto_merge
  delete_branch_on_merge = each.value.delete_branch_on_merge
  allow_update_branch    = each.value.allow_update_branch
  # A squash merge lands with the pull request's title as its subject, which the commit-messages
  # ruleset judges.
  squash_merge_commit_title   = "PR_TITLE"
  squash_merge_commit_message = "COMMIT_MESSAGES"
  # The organization requires sign-off on web commits. GitHub then refuses web_commit_signoff_required
  # in any repository update, even set to true, so the repository leaves it unset.

  security_and_analysis {
    secret_scanning {
      status = each.value.secret_scanning ? "enabled" : "disabled"
    }
    secret_scanning_push_protection {
      status = each.value.push_protection ? "enabled" : "disabled"
    }
  }

  dynamic "template" {
    for_each = each.value.template == null || each.value.is_template ? [] : [each.value.template]

    content {
      owner      = split("/", template.value)[0]
      repository = split("/", template.value)[1]
    }
  }

  # Removing a repository from the configuration archives it, and its history stays.
  archive_on_destroy = true

  lifecycle {
    # A template applies only when the repository is created, so an adopted one has none.
    ignore_changes = [template]
  }
}

resource "github_repository_pages" "this" {
  for_each = { for name, repository in var.repositories : name => repository if repository.pages }

  repository = github_repository.this[each.key].name
  build_type = "workflow"
}

# A workflow token is read-only unless its job asks for more, and it never approves a pull request.
resource "github_workflow_repository_permissions" "this" {
  for_each = var.repositories

  repository                       = github_repository.this[each.key].name
  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = false
}

resource "github_repository_vulnerability_alerts" "this" {
  for_each = var.repositories

  repository = github_repository.this[each.key].name
  enabled    = each.value.vulnerability_alerts
}

# Security updates need the alerts they answer.
resource "github_repository_dependabot_security_updates" "this" {
  for_each = var.repositories

  repository = github_repository_vulnerability_alerts.this[each.key].repository
  enabled    = each.value.dependabot_security_updates
}

# The complete set of each repository's teams: its class's area teams, the tier teams on a
# dispatcher, and the admin team. A team or person granted by hand loses access at the next apply.
# A team name is its slug, and known before the team exists.
resource "github_repository_collaborators" "this" {
  for_each = var.repositories

  repository = github_repository.this[each.key].name

  dynamic "team" {
    for_each = merge(
      { for tier, permission in var.tiers : github_team.area["${tier}-${each.value.class}"].name => permission },
      each.value.dispatcher ? { for tier in keys(var.tiers) : github_team.tier[tier].name => "push" } : {},
      { (var.admin_team) = "admin" },
    )

    content {
      team_id    = team.key
      permission = team.value
    }
  }
}

resource "github_issue_label" "this" {
  for_each = local.labels

  repository  = github_repository.this[each.value.repository].name
  name        = each.value.name
  color       = var.labels[each.value.name].color
  description = var.labels[each.value.name].description
}
