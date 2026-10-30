# Discovery reads each repository's code on its default branch, which stays the source of truth:
# the jobs of main.yaml, the secrets and environments every workflow names, and the major version of
# the root package.json.
locals {
  default_branch = "master"

  # The workflows that report the always-required checks. A repository without them is not ready, and
  # gets no rulesets, environments or secret access until a commit adds them.
  governance_workflows = ["merge-gate.yaml", "epic-freeze.yaml", "review-gate.yaml", "check-dependencies.yaml"]

  # GitHub Actions' App, which posts every workflow job's check.
  actions_app = 15368
}

# A missing file reads as no content, an empty repository's included.
data "github_repository_file" "main" {
  for_each = var.repositories

  repository = each.key
  branch     = local.default_branch
  file       = ".github/workflows/main.yaml"
}

data "github_tree" "default_branch" {
  for_each = { for name, file in data.github_repository_file.main : name => file if file.content != null }

  repository = each.key
  tree_sha   = local.default_branch
  recursive  = true
}

locals {
  workflow_paths = {
    for name, tree in data.github_tree.default_branch : name => [
      for entry in tree.entries : entry.path if entry.type == "blob" && can(regex("^\\.github/workflows/[^/]+\\.ya?ml$", entry.path))
    ]
  }

  ready = toset([
    for name, paths in local.workflow_paths : name
    if alltrue([for file in local.governance_workflows : contains(paths, ".github/workflows/${file}")])
  ])
}

data "github_repository_file" "workflow" {
  for_each = toset(flatten([for name in local.ready : [for path in local.workflow_paths[name] : "${name}:${path}"]]))

  repository = split(":", each.key)[0]
  branch     = local.default_branch
  file       = split(":", each.key)[1]
}

data "github_repository_file" "package" {
  for_each = local.ready

  repository = each.key
  branch     = local.default_branch
  file       = "package.json"
}

locals {
  workflows = { for key, file in data.github_repository_file.workflow : key => yamldecode(file.content) }

  discovered = {
    for name in local.ready : name => {
      # A job's check is its name, else its id. Reporting jobs and those that run only on master gate
      # nothing. An always-required check wins over a job of the same name.
      checks = merge(
        {
          for context, ids in {
            for id, job in try(local.workflows["${name}:.github/workflows/main.yaml"].jobs, {}) : try(tostring(job.name), id) => id...
            if !startswith(id, "report-") && !strcontains(try(tostring(job["if"]), ""), "github.ref == 'refs/heads/master'")
          } : context => local.actions_app
        },
        {
          merge-gate         = var.bots.agent
          epic-freeze        = var.bots.agent
          check-dependencies = local.actions_app
          review-gate        = var.bots.agent
        },
      )

      # Decoding drops the comments, so a secret only a comment names counts for nothing.
      secrets = toset(flatten([
        for key, workflow in local.workflows : [for match in regexall("\\bsecrets\\.([A-Za-z_][A-Za-z0-9_]*)", jsonencode(workflow)) : match[0]]
        if startswith(key, "${name}:")
      ]))

      # A job names its environment directly or as the name of an environment map.
      environments = toset(flatten([
        for key, workflow in local.workflows : [
          for job in values(try(workflow.jobs, {})) : try(tostring(job.environment), tostring(job.environment.name))
          if can(tostring(job.environment)) || can(tostring(job.environment.name))
        ]
        if startswith(key, "${name}:")
      ]))

      # A repository without a version reads as major 0.
      major = try(tonumber(split(".", jsondecode(data.github_repository_file.package[name].content).version)[0]), 0)
    }
  }
}
