# Discovery reads each repository's code on its default branch, which stays the source of truth:
# the jobs of main.yaml, the secrets and environments every workflow names, and the major version of
# the root package.json.
locals {
  default_branch = "master"

  # GitHub Actions' App, which posts every workflow job's check.
  actions_app = 15368
}

# Each file is one contents API call. github_repository_file would also page through the file's whole
# commit history for attributes nothing here reads, which made up four fifths of every plan's calls.
#
# A repository is ready once its default branch holds main.yaml. Until then it gets no rulesets,
# environments or secret access. Each repository names its other workflows as it likes, so readiness
# never depends on their names. A missing file answers 404, an empty repository's included.
data "github_rest_api" "main" {
  for_each = var.repositories

  endpoint = "repos/${var.owner}/${each.key}/contents/.github/workflows/main.yaml?ref=${local.default_branch}"
}

locals {
  ready = toset([for name, file in data.github_rest_api.main : name if file.code == 200])
}

data "github_tree" "default_branch" {
  for_each = local.ready

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
}

data "github_rest_api" "workflow" {
  for_each = toset(flatten([for name in local.ready : [for path in local.workflow_paths[name] : "${name}:${path}"]]))

  endpoint = "repos/${var.owner}/${split(":", each.key)[0]}/contents/${split(":", each.key)[1]}?ref=${local.default_branch}"
}

data "github_rest_api" "package" {
  for_each = local.ready

  endpoint = "repos/${var.owner}/${each.key}/contents/package.json?ref=${local.default_branch}"
}

locals {
  workflows = { for key, file in data.github_rest_api.workflow : key => yamldecode(base64decode(jsondecode(file.body).content)) }

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
      major = try(tonumber(split(".", jsondecode(base64decode(jsondecode(data.github_rest_api.package[name].body).content)).version)[0]), 0)
    }
  }
}
