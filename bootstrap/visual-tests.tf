variable "visual_test_repositories" {
  description = "Repositories using Drive visual-test evidence; add one once to generate both keyless identities."
  type = map(object({
    repository    = string
    repository_id = string
  }))
  default = {
    studio = {
      repository    = "a-novel/platform-studio"
      repository_id = "1338436652"
    }
    template = {
      repository    = "a-novel/platform-template"
      repository_id = "1310148363"
    }
    uikit = {
      repository    = "a-novel-kit/uikit"
      repository_id = "1310094565"
    }
  }
  validation {
    condition = alltrue([for slug, github in var.visual_test_repositories :
      can(regex("^[a-z][a-z0-9-]{0,9}[a-z0-9]$", slug)) &&
      can(regex("^(a-novel/platform-[a-z0-9-]+|a-novel-kit/uikit)$", github.repository)) &&
      can(regex("^[0-9]+$", github.repository_id))
    ])
    error_message = "Use a 2–11 character slug, an a-novel/platform-* repository or a-novel-kit/uikit, and its numeric GitHub ID."
  }
  validation {
    condition = (
      length(distinct([for github in var.visual_test_repositories : github.repository])) == length(var.visual_test_repositories) &&
      length(distinct([for github in var.visual_test_repositories : github.repository_id])) == length(var.visual_test_repositories)
    )
    error_message = "Each repository must have a distinct name and numeric GitHub ID."
  }
}

locals {
  # GitHub's numeric organization IDs, which each provider pins beside the repository ID.
  visual_owner_ids = { "a-novel" = local.github.owner_id, "a-novel-kit" = "187672320" }

  visual_identities = merge([for slug, github in var.visual_test_repositories : {
    for role in ["ci", "maintenance"] : "${slug}-${role}" => {
      slug          = slug
      role          = role
      owner_id      = local.visual_owner_ids[split("/", github.repository)[0]]
      repository    = github.repository
      repository_id = github.repository_id
      account_id    = "${slug}-visual-${role}"
      workflow = role == "ci" ? (
        "assertion.workflow_ref == '${github.repository}/.github/workflows/main.yaml@' + assertion.ref"
        ) : (
        "(assertion.workflow_ref == '${github.repository}/.github/workflows/main.yaml@refs/heads/master' && assertion.event_name == 'push') || (assertion.workflow_ref == '${github.repository}/.github/workflows/visual-tests.yaml@refs/heads/master' && assertion.event_name in ['workflow_run', 'pull_request_target', 'delete', 'schedule'])"
      )
      # GitHub issues no OIDC token to fork pull requests, so a pull request run is a collaborator's branch.
      condition = role == "ci" ? "(${join(" || ", [
        "(assertion.ref.startsWith('refs/heads/') && assertion.event_name in ['push', 'merge_group'])",
        "(assertion.event_name == 'pull_request' && assertion.base_ref == 'master' && assertion.ref.startsWith('refs/pull/'))",
      ])})" : "assertion.ref == 'refs/heads/master'"
    }
  }]...)
}

resource "google_service_account" "visual_tests" {
  for_each = local.visual_identities

  project      = var.management_project_id
  account_id   = each.value.account_id
  display_name = "${each.value.slug} visual ${each.value.role}"
  description  = "Keyless visual-test storage identity for ${each.value.repository} ${each.value.role} runs."

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

resource "google_iam_workload_identity_pool_provider" "visual_tests" {
  for_each = local.visual_identities

  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = each.value.account_id
  display_name                       = "${each.value.slug} visual ${each.value.role}"
  description                        = "Trust ${each.value.slug} ${each.value.role} workflow events for Drive visual-test storage."
  deletion_policy                    = "PREVENT"

  attribute_mapping = {
    # GitHub subjects contain refs; merge-queue and long branch refs exceed Google's 127-byte limit.
    "google.subject"                = "'${each.value.account_id}:' + assertion.repository_id + ':' + assertion.run_id + ':' + assertion.run_attempt"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.ref"                 = "assertion.ref"
    "attribute.workflow_ref"        = "assertion.workflow_ref"
    "attribute.event_name"          = "assertion.event_name"
    # Provider-owned constants keep these identities disjoint from infra automation.
    "attribute.trust_boundary" = "'${each.value.account_id}'"
  }
  attribute_condition = join(" && ", [
    "assertion.repository_owner_id == '${each.value.owner_id}'",
    "assertion.repository_id == '${each.value.repository_id}'",
    "assertion.repository == '${each.value.repository}'",
    "(${each.value.workflow})",
    each.value.condition,
  ])

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account_iam_member" "visual_tests" {
  for_each = local.visual_identities

  service_account_id = google_service_account.visual_tests[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.trust_boundary/${each.value.account_id}"
}

output "visual_tests" {
  description = "Per-repository Drive handoff; a Workspace administrator verifies folder access and maintenance deletion authority before activation."
  value = {
    oauth_scope             = "https://www.googleapis.com/auth/drive"
    maintenance_parent_role = "organizer"
    ci_folder_roles         = { references = "reader", results = "writer" }
    repositories = { for slug, github in var.visual_test_repositories : slug => {
      repository = github.repository
      folders = {
        references = "${slug}/ci/references"
        results    = "${slug}/ci/results"
      }
      identities = { for role in ["ci", "maintenance"] : role => {
        service_account   = google_service_account.visual_tests["${slug}-${role}"].email
        identity_provider = google_iam_workload_identity_pool_provider.visual_tests["${slug}-${role}"].name
      } }
    } }
  }

  depends_on = [
    google_project_service.management["drive.googleapis.com"],
    google_service_account_iam_member.visual_tests,
  ]
}
