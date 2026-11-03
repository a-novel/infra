# Every file a mocked data source reads holds the same workflow, and every tree lists main.yaml and the
# governance workflows.
mock_provider "github" {
  mock_resource "github_team" {
    defaults = { id = "1" }
  }

  mock_data "github_team" {
    defaults = { id = "7" }
  }

  # A mock takes no function call, so each file is the contents API's answer: this workflow,
  # base64-encoded and wrapped every 60 characters as GitHub sends it.
  #
  #   on: pull_request
  #   jobs:
  #     lint-go:
  #       name: lint-go
  #       runs-on: ubuntu-24.04
  #       steps:
  #         - run: upload "${{ secrets.CODECOV_TOKEN }}" # secrets.IN_A_COMMENT
  #     release:
  #       runs-on: ubuntu-24.04
  #       environment: release
  #     report-coverage:
  #       runs-on: ubuntu-24.04
  #       environment: plan
  #     publish:
  #       if: github.event_name == 'push' && github.ref == 'refs/heads/master'
  #       runs-on: ubuntu-24.04
  #       environment:
  #         name: governance
  #       steps:
  #         - run: sign "${{ secrets.AGENT_BOT_PRIVATE_KEY }}"
  mock_data "github_rest_api" {
    defaults = {
      code = 200
      body = <<-EOT
        {"content": "b246IHB1bGxfcmVxdWVzdApqb2JzOgogIGxpbnQtZ286CiAgICBuYW1lOiBs\naW50LWdvCiAgICBydW5zLW9uOiB1YnVudHUtMjQuMDQKICAgIHN0ZXBzOgog\nICAgICAtIHJ1bjogdXBsb2FkICIke3sgc2VjcmV0cy5DT0RFQ09WX1RPS0VO\nIH19IiAjIHNlY3JldHMuSU5fQV9DT01NRU5UCiAgcmVsZWFzZToKICAgIHJ1\nbnMtb246IHVidW50dS0yNC4wNAogICAgZW52aXJvbm1lbnQ6IHJlbGVhc2UK\nICByZXBvcnQtY292ZXJhZ2U6CiAgICBydW5zLW9uOiB1YnVudHUtMjQuMDQK\nICAgIGVudmlyb25tZW50OiBwbGFuCiAgcHVibGlzaDoKICAgIGlmOiBnaXRo\ndWIuZXZlbnRfbmFtZSA9PSAncHVzaCcgJiYgZ2l0aHViLnJlZiA9PSAncmVm\ncy9oZWFkcy9tYXN0ZXInCiAgICBydW5zLW9uOiB1YnVudHUtMjQuMDQKICAg\nIGVudmlyb25tZW50OgogICAgICBuYW1lOiBnb3Zlcm5hbmNlCiAgICBzdGVw\nczoKICAgICAgLSBydW46IHNpZ24gIiR7eyBzZWNyZXRzLkFHRU5UX0JPVF9Q\nUklWQVRFX0tFWSB9fSIK\n", "encoding": "base64"}
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
  owner              = "a-novel"
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
      delete_branch_on_merge = true, allow_update_branch = true
      secret_scanning        = true, push_protection = true, vulnerability_alerts = true, dependabot_security_updates = false, pages = false
    }
    "service-genai" = {
      class                  = "service", topics = [], template = "a-novel/service-template", dispatcher = false, is_template = false, tags_ruleset = true, admins_only = false
      has_issues             = true, has_wiki = false, has_projects = true, has_discussions = true
      allow_squash_merge     = true, allow_merge_commit = false, allow_rebase_merge = false, allow_auto_merge = true
      delete_branch_on_merge = true, allow_update_branch = true
      secret_scanning        = true, push_protection = true, vulnerability_alerts = true, dependabot_security_updates = true, pages = true
    }
    "infra" = {
      class                  = "infra", topics = [], dispatcher = false, is_template = false, tags_ruleset = false, admins_only = true
      has_issues             = true, has_wiki = false, has_projects = true, has_discussions = false
      allow_squash_merge     = true, allow_merge_commit = false, allow_rebase_merge = false, allow_auto_merge = true
      delete_branch_on_merge = true, allow_update_branch = true
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
    condition     = local.discovered["service-genai"].environments == toset(["release", "plan", "governance"])
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
    condition     = toset(keys(github_repository_environment.this)) == toset(["service-genai:release", "service-genai:governance", "service-genai:plan", ".github:release", ".github:governance", ".github:plan", "infra:release", "infra:governance", "infra:plan"])
    error_message = "A repository gets the release and plan environments its workflows name, and governance when they name a privileged secret."
  }

  assert {
    condition = (
      length(github_repository_environment.this["infra:plan"].deployment_branch_policy) == 0 &&
      length(one(github_repository_environment.this["infra:plan"].reviewers).teams) > 0 &&
      !github_repository_environment.this["infra:plan"].prevent_self_review
    )
    error_message = "A pull request's plan waits for a maintainer, an owner or an admin, on any branch, its author included."
  }

  assert {
    condition     = length([for key, policy in local.deployment_policies : key if startswith(key, "infra:")]) == 2 && length([for key, policy in local.deployment_policies : key if startswith(key, "service-genai:")]) == 6
    error_message = "An environment opens on the default branch, plus release lines and version tags where the tags ruleset guards them."
  }

  assert {
    condition     = jsonencode(output.environments) == jsonencode([".github:governance", ".github:plan", ".github:release", "infra:governance", "infra:plan", "infra:release", "service-genai:governance", "service-genai:plan", "service-genai:release"])
    error_message = "Prune reads the deployment patterns of the managed environments alone, so GitHub's own and infra's deploy environments keep theirs."
  }

  assert {
    condition     = jsonencode(output.governance_secrets) == jsonencode({ ".github" = ["AGENT_BOT_PRIVATE_KEY"], infra = ["AGENT_BOT_PRIVATE_KEY"], "service-genai" = ["AGENT_BOT_PRIVATE_KEY"] })
    error_message = "Each governance environment holds exactly the privileged secrets its repository's workflows name, never a scoped one."
  }
}

run "gives_a_repository_its_own_apps" {
  command = plan

  variables {
    dedicated_bots = {
      infra = {
        agent        = { id = 900, client_id = "Iv23-infra-agent", login = "infra-agent[bot]" }
        dependencies = { id = 901, client_id = "Iv23-infra-dependencies", login = "infra-dependencies[bot]" }
      }
    }
  }

  assert {
    condition = (
      local.discovered["infra"].checks["review-gate"] == 900 && local.discovered["infra"].checks["merge-gate"] == 900 &&
      local.discovered["service-genai"].checks["review-gate"] == 100
    )
    error_message = "A repository with Apps of its own takes its App-posted checks from its own Agent App, and the others from the organization's."
  }

  assert {
    condition = (
      toset(keys(github_actions_variable.dedicated_bot)) == toset(["infra:AGENT_BOT_CLIENT_ID", "infra:AGENT_BOT_LOGIN", "infra:DEPENDENCY_BOT_CLIENT_ID", "infra:DEPENDENCY_BOT_LOGIN"]) &&
      github_actions_variable.dedicated_bot["infra:AGENT_BOT_LOGIN"].value == "infra-agent[bot]"
    )
    error_message = "A repository with Apps of its own names them to its workflows through repository variables."
  }
}
