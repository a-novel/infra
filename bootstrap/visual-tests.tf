variable "visual_test_platforms" {
  description = "Platforms using Drive evidence; add a repository once to generate both keyless identities."
  type = map(object({
    repository    = string
    repository_id = string
  }))
  default = {
    studio = {
      repository    = "a-novel/platform-studio"
      repository_id = "1338436652"
    }
  }
  validation {
    condition = alltrue([for platform, github in var.visual_test_platforms :
      can(regex("^[a-z][a-z0-9-]{0,9}[a-z0-9]$", platform)) &&
      can(regex("^a-novel/platform-[a-z0-9-]+$", github.repository)) &&
      can(regex("^[0-9]+$", github.repository_id))
    ])
    error_message = "Use a 2–11 character platform slug, an a-novel/platform-* repository and its numeric GitHub ID."
  }
  validation {
    condition = (
      length(distinct([for github in var.visual_test_platforms : github.repository])) == length(var.visual_test_platforms) &&
      length(distinct([for github in var.visual_test_platforms : github.repository_id])) == length(var.visual_test_platforms)
    )
    error_message = "Each platform must have a distinct repository and numeric GitHub ID."
  }
}

locals {
  visual_identities = merge([for platform, github in var.visual_test_platforms : {
    for role in ["ci", "maintenance"] : "${platform}-${role}" => {
      platform      = platform
      role          = role
      repository    = github.repository
      repository_id = github.repository_id
      account_id    = "${platform}-visual-${role}"
      workflow = role == "ci" ? (
        "assertion.workflow_ref == '${github.repository}/.github/workflows/main.yaml@' + assertion.ref"
        ) : (
        "(assertion.workflow_ref == '${github.repository}/.github/workflows/main.yaml@refs/heads/master' && assertion.event_name == 'push') || (assertion.workflow_ref == '${github.repository}/.github/workflows/visual-tests.yaml@refs/heads/master' && assertion.event_name in ['workflow_run', 'pull_request_target', 'delete', 'schedule'])"
      )
      condition = role == "ci" ? "assertion.ref.startsWith('refs/heads/') && assertion.event_name in ['push', 'merge_group']" : "assertion.ref == 'refs/heads/master'"
    }
  }]...)
}

resource "google_service_account" "visual_tests" {
  for_each = local.visual_identities

  project      = var.management_project_id
  account_id   = each.value.account_id
  display_name = "${each.value.platform} visual ${each.value.role}"
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
  display_name                       = "${each.value.platform} visual ${each.value.role}"
  description                        = "Trust ${each.value.platform} ${each.value.role} workflow events for Drive visual-test storage."
  deletion_policy                    = "PREVENT"

  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.ref"                 = "assertion.ref"
    "attribute.workflow_ref"        = "assertion.workflow_ref"
    "attribute.event_name"          = "assertion.event_name"
    # Provider-owned constants keep these identities disjoint from infra automation.
    "attribute.trust_boundary" = "'${each.value.account_id}'"
  }
  attribute_condition = join(" && ", [
    "assertion.repository_owner_id == '131281268'",
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
  description = "Per-platform Drive handoff; a Workspace administrator verifies folder access and maintenance deletion authority before activation."
  value = {
    oauth_scope             = "https://www.googleapis.com/auth/drive"
    maintenance_parent_role = "organizer"
    ci_folder_roles         = { references = "reader", results = "writer" }
    platforms = { for platform, github in var.visual_test_platforms : platform => {
      repository = github.repository
      folders = {
        references = "${platform}/ci/references"
        results    = "${platform}/ci/results"
      }
      identities = { for role in ["ci", "maintenance"] : role => {
        service_account   = google_service_account.visual_tests["${platform}-${role}"].email
        identity_provider = google_iam_workload_identity_pool_provider.visual_tests["${platform}-${role}"].name
      } }
    } }
  }

  depends_on = [
    google_project_service.management["drive.googleapis.com"],
    google_service_account_iam_member.visual_tests,
  ]
}
