# Every file a mocked data source reads holds the same workflow, and every tree lists main.yaml and the
# governance workflows.
mock_provider "github" {
  mock_resource "github_team" {
    defaults = { id = "1" }
  }

  mock_data "github_team" {
    defaults = { id = "7" }
  }

  mock_data "github_repository_file" {
    defaults = {
      content = <<-EOT
        on: pull_request
        jobs:
          lint-go:
            name: lint-go
            runs-on: ubuntu-24.04
            steps:
              - run: upload "$${{ secrets.CODECOV_TOKEN }}" # secrets.IN_A_COMMENT
          release:
            runs-on: ubuntu-24.04
            environment: release
          report-coverage:
            runs-on: ubuntu-24.04
          publish:
            if: github.event_name == 'push' && github.ref == 'refs/heads/master'
            runs-on: ubuntu-24.04
            environment:
              name: governance
            steps:
              - run: sign "$${{ secrets.AGENT_BOT_PRIVATE_KEY }}"
      EOT
    }
  }

  mock_data "github_tree" {
    defaults = {
      entries = [
        { path = ".github/workflows/main.yaml", type = "blob", mode = "100644", size = 1, sha = "1" },
        { path = ".github/workflows/merge-gate.yaml", type = "blob", mode = "100644", size = 1, sha = "2" },
        { path = ".github/workflows/epic-freeze.yaml", type = "blob", mode = "100644", size = 1, sha = "3" },
        { path = ".github/workflows/review-gate.yaml", type = "blob", mode = "100644", size = 1, sha = "4" },
        { path = ".github/workflows/check-dependencies.yaml", type = "blob", mode = "100644", size = 1, sha = "5" },
        { path = "README.md", type = "blob", mode = "100644", size = 1, sha = "6" },
      ]
    }
  }
}

variables {
  tiers              = { developers = "push", maintainers = "maintain", owners = "admin" }
  admin_team         = "core"
  labels             = { documentation = { color = "0075ca", description = "Improvements or additions to documentation" } }
  bots               = { agent = 100, dependencies = 200, release = 300 }
  scoped_secrets     = ["CODECOV_TOKEN", "TOKEN_EXPIRY_ADMIN"]
  governance_secrets = ["AGENT_BOT_PRIVATE_KEY"]
  repositories = {
    ".github" = {
      class                  = "meta", topics = [], dispatcher = true, is_template = false, tags_ruleset = true, admins_only = false
      has_issues             = true, has_wiki = false, has_projects = true, has_discussions = true
      allow_squash_merge     = true, allow_merge_commit = false, allow_rebase_merge = false, allow_auto_merge = true
      delete_branch_on_merge = true, allow_update_branch = true, web_commit_signoff_required = true
      secret_scanning        = true, push_protection = true, vulnerability_alerts = true, dependabot_security_updates = false, pages = false
    }
    "service-genai" = {
      class                  = "service", topics = [], template = "a-novel/service-template", dispatcher = false, is_template = false, tags_ruleset = true, admins_only = false
      has_issues             = true, has_wiki = false, has_projects = true, has_discussions = true
      allow_squash_merge     = true, allow_merge_commit = false, allow_rebase_merge = false, allow_auto_merge = true
      delete_branch_on_merge = true, allow_update_branch = true, web_commit_signoff_required = true
      secret_scanning        = true, push_protection = true, vulnerability_alerts = true, dependabot_security_updates = true, pages = true
    }
    "infra" = {
      class                  = "infra", topics = [], dispatcher = false, is_template = false, tags_ruleset = false, admins_only = true
      has_issues             = true, has_wiki = false, has_projects = true, has_discussions = false
      allow_squash_merge     = true, allow_merge_commit = false, allow_rebase_merge = false, allow_auto_merge = true
      delete_branch_on_merge = true, allow_update_branch = true, web_commit_signoff_required = true
      secret_scanning        = true, push_protection = true, vulnerability_alerts = true, dependabot_security_updates = false, pages = false
    }
  }
}

run "grants_each_class_its_area_teams" {
  command = plan

  assert {
    condition     = toset(keys(github_team.area)) == toset(["developers-meta", "maintainers-meta", "owners-meta", "developers-service", "maintainers-service", "owners-service", "developers-infra", "maintainers-infra", "owners-infra"])
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
    condition     = contains(keys(github_issue_label.this), "service-genai:documentation") && length(github_issue_label.this) == 3
    error_message = "Every repository carries every managed label, keyed as its import ID."
  }

  assert {
    condition     = alltrue([for repository in github_repository.this : repository.archive_on_destroy])
    error_message = "Removing a repository from the configuration must archive it, never delete it."
  }
}

run "derives_config_from_the_workflows" {
  command = plan

  assert {
    condition = local.discovered["service-genai"].checks == {
      lint-go = 15368, release = 15368, merge-gate = 100, epic-freeze = 100, check-dependencies = 15368, review-gate = 100
    }
    error_message = "The required checks are the always set, bound to its Apps, plus every main.yaml job but reporting and master-only ones."
  }

  assert {
    condition     = local.discovered["service-genai"].secrets == toset(["CODECOV_TOKEN", "AGENT_BOT_PRIVATE_KEY"])
    error_message = "Discovery counts the secrets a workflow's values name, never one only a comment names."
  }

  assert {
    condition     = local.discovered["service-genai"].environments == toset(["release", "governance"])
    error_message = "A job names its environment directly or as the name of an environment map."
  }

  assert {
    condition     = toset([for key, ruleset in local.rulesets : ruleset.ruleset if ruleset.repository == "service-genai"]) == toset(["master", "commit-messages", "require-approval", "tags", "release-lines"])
    error_message = "A repository whose version has no major past 0 retires no line, and a class with tags guards its tags and release lines."
  }

  assert {
    condition     = toset([for key, ruleset in local.rulesets : ruleset.ruleset if ruleset.repository == "infra"]) == toset(["master", "commit-messages", "require-approval"])
    error_message = "A class without tags gets neither the tags nor the release-lines ruleset."
  }

  assert {
    condition     = [for actor in local.bypass_actors["infra:master"] : actor.actor_type] == ["OrganizationAdmin", "RepositoryRole"]
    error_message = "A class whose merges deploy production lets only admins bypass."
  }

  assert {
    condition     = contains(local.bypass_actors["service-genai:require-approval"], { actor_id = 300, actor_type = "Integration", bypass_mode = "exempt" }) && contains(local.bypass_actors["service-genai:master"], { actor_id = 300, actor_type = "Integration", bypass_mode = "always" })
    error_message = "The release App writes the default branch directly, and is exempt from the approval its pull requests would need."
  }

  assert {
    condition     = [for actor in local.bypass_actors["service-genai:commit-messages"] : "${actor.actor_id}:${actor.bypass_mode}"] == ["29110:exempt"] && length(local.bypass_actors[".github:commit-messages"]) == 0
    error_message = "Dependabot bypasses the commit-messages ruleset only where it runs."
  }

  assert {
    condition     = toset(keys(github_repository_environment.this)) == toset(["service-genai:release", "service-genai:governance", ".github:release", ".github:governance", "infra:release", "infra:governance"])
    error_message = "A repository gets the release environment its workflows name, and governance when they name a privileged secret."
  }

  assert {
    condition     = length([for key, policy in local.deployment_policies : key if startswith(key, "infra:")]) == 2 && length([for key, policy in local.deployment_policies : key if startswith(key, "service-genai:")]) == 6
    error_message = "An environment opens on the default branch, plus release lines and version tags where the tags ruleset guards them."
  }

  assert {
    condition     = jsonencode(output.environments) == jsonencode([".github:governance", ".github:release", "infra:governance", "infra:release", "service-genai:governance", "service-genai:release"])
    error_message = "Prune reads the deployment patterns of the managed environments alone, so GitHub's own and infra's deploy environments keep theirs."
  }

  assert {
    condition     = jsonencode(output.governance_secrets) == jsonencode({ ".github" = ["AGENT_BOT_PRIVATE_KEY"], infra = ["AGENT_BOT_PRIVATE_KEY"], "service-genai" = ["AGENT_BOT_PRIVATE_KEY"] })
    error_message = "Each governance environment holds exactly the privileged secrets its repository's workflows name, never a scoped one."
  }
}
