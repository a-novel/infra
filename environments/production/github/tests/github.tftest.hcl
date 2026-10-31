# Plans the committed production inputs against mocked providers.
mock_provider "google" {}

mock_provider "github" {
  alias = "a_novel"
}

mock_provider "github" {
  alias = "a_novel_kit"
}

# The module's own tests cover its resources.
override_module {
  target = module.a_novel
}

override_module {
  target = module.a_novel_kit
}

run "plans_with_the_plan_app" {
  command = plan

  assert {
    condition     = local.app == "plan"
    error_message = "Pull requests and the drift check run pull-request code, so they must read only the Plan App's key."
  }
}

run "deploys_with_the_deploy_app" {
  command = plan

  variables {
    writer = true
  }

  assert {
    condition     = local.app == "deploy"
    error_message = "Only a deploy may read the Deploy App's key."
  }
}

run "resolves_each_repository_from_its_class" {
  command = plan

  assert {
    condition = alltrue([for repository in values(local.repositories) :
      repository.pages == (contains(["service", "platform"], repository.class) || contains(["a-novel-kit/stack", "a-novel-kit/uikit"], "${repository.owner}/${repository.name}"))
    ])
    error_message = "Services and platforms publish their docs on Pages, as do the two libraries that override it."
  }

  assert {
    condition = alltrue([for repository in values(local.repositories) :
      repository.dependabot_security_updates == contains(["library", "workflows"], repository.class) && repository.vulnerability_alerts
    ])
    error_message = "Only the libraries and workflows take Dependabot's security updates, and every repository keeps its alerts."
  }

  assert {
    condition = alltrue([for repository in values(local.repositories) :
      !repository.allow_merge_commit && !repository.allow_rebase_merge && repository.allow_squash_merge && repository.web_commit_signoff_required
    ])
    error_message = "Every repository merges by squash only, so the commit-messages ruleset judges each pull request's title, and requires sign-off."
  }

  assert {
    condition     = toset([for repository in values(local.repositories) : "${repository.owner}/${repository.name}" if repository.dispatcher]) == toset(["a-novel/.github", "a-novel-kit/stack"])
    error_message = "Each organization's bot-comment dispatcher, and only it, grants the tier teams Write."
  }

  assert {
    condition     = toset([for repository in values(local.repositories) : repository.name if repository.is_template]) == toset(["service-template", "platform-template"])
    error_message = "Only the two templates are template repositories."
  }
}

run "gives_the_scripts_their_apps_and_repositories" {
  command = plan

  assert {
    condition     = toset(flatten([for owner, organization in output.organizations : [for name in organization.repositories : "${owner}/${name}"]])) == toset(keys(var.repositories))
    error_message = "repository-asserts.mjs holds every repository to its settings, ready or not, so the output lists them all, not only those with a governance environment."
  }

  assert {
    condition     = alltrue([for owner, organization in output.organizations : organization.apps.plan.key.secret == "production-github-plan-key-${owner}" && organization.apps.deploy.key.secret == "production-github-deploy-key-${owner}"])
    error_message = "Pull request plans prune as the Plan App and deploys as the Deploy App, each with its own key, the only one its identity reads."
  }
}
