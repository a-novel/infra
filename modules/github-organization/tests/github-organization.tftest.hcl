mock_provider "github" {
  mock_resource "github_team" {
    defaults = { id = "1" }
  }
}

variables {
  tiers      = { developers = "push", maintainers = "maintain", owners = "admin" }
  admin_team = "core"
  labels     = { documentation = { color = "0075ca", description = "Improvements or additions to documentation" } }
  repositories = {
    ".github" = {
      class                  = "meta", topics = [], dispatcher = true, is_template = false
      has_issues             = true, has_wiki = false, has_projects = true, has_discussions = true
      allow_squash_merge     = true, allow_merge_commit = false, allow_rebase_merge = false, allow_auto_merge = true
      delete_branch_on_merge = true, allow_update_branch = true, web_commit_signoff_required = true
      secret_scanning        = true, push_protection = true, vulnerability_alerts = true, dependabot_security_updates = false, pages = false
    }
    "service-genai" = {
      class                  = "service", topics = [], template = "a-novel/service-template", dispatcher = false, is_template = false
      has_issues             = true, has_wiki = false, has_projects = true, has_discussions = true
      allow_squash_merge     = true, allow_merge_commit = false, allow_rebase_merge = false, allow_auto_merge = true
      delete_branch_on_merge = true, allow_update_branch = true, web_commit_signoff_required = true
      secret_scanning        = true, push_protection = true, vulnerability_alerts = true, dependabot_security_updates = false, pages = true
    }
  }
}

run "grants_each_class_its_area_teams" {
  command = plan

  assert {
    condition     = toset(keys(github_team.area)) == toset(["developers-meta", "maintainers-meta", "owners-meta", "developers-service", "maintainers-service", "owners-service"])
    error_message = "Each tier needs one area team per class the organization has a repository of."
  }

  assert {
    condition = (
      { for team in github_repository_collaborators.this["service-genai"].team : team.team_id => team.permission } ==
      { "developers-service" = "push", "maintainers-service" = "maintain", "owners-service" = "admin", core = "admin" }
    )
    error_message = "A repository holds its class's area teams at their tier's role, and the admin team, and nothing else."
  }

  assert {
    condition = (
      { for team in github_repository_collaborators.this[".github"].team : team.team_id => team.permission } ==
      { "developers-meta" = "push", "maintainers-meta" = "maintain", "owners-meta" = "admin", developers = "push", maintainers = "push", owners = "push", core = "admin" }
    )
    error_message = "A dispatcher also grants the tier teams Write, so any member can post bot comments."
  }

  assert {
    condition     = toset(keys(github_repository_pages.this)) == toset(["service-genai"])
    error_message = "Only a repository whose settings turn Pages on publishes a site."
  }

  assert {
    condition     = toset(keys(github_issue_label.this)) == toset([".github:documentation", "service-genai:documentation"])
    error_message = "Every repository carries every managed label, keyed as its import ID."
  }

  assert {
    condition     = alltrue([for repository in github_repository.this : repository.archive_on_destroy])
    error_message = "Removing a repository from the configuration must archive it, never delete it."
  }
}
