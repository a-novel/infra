locals {
  studio_github = {
    owner_id      = "131281268"
    repository_id = "1338436652"
    repository    = "a-novel/platform-studio"
  }
  visual_identities = {
    ci = {
      account_id = "studio-visual-ci"
      workflow   = "assertion.workflow_ref == 'a-novel/platform-studio/.github/workflows/main.yaml@' + assertion.ref"
      condition  = "assertion.ref.startsWith('refs/heads/') && assertion.event_name in ['push', 'merge_group']"
    }
    maintenance = {
      account_id = "studio-visual-maintenance"
      workflow   = "(assertion.workflow_ref == 'a-novel/platform-studio/.github/workflows/main.yaml@refs/heads/master' && assertion.event_name == 'push') || (assertion.workflow_ref == 'a-novel/platform-studio/.github/workflows/visual-tests.yaml@refs/heads/master' && assertion.event_name in ['workflow_run', 'pull_request_target', 'delete', 'schedule'])"
      condition  = "assertion.ref == 'refs/heads/master'"
    }
  }
}

resource "google_service_account" "visual_tests" {
  for_each = local.visual_identities

  project      = var.management_project_id
  account_id   = each.value.account_id
  display_name = "Studio visual tests ${each.key}"
  description  = "Keyless visual-test storage identity for Studio ${each.key} runs."

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

resource "google_iam_workload_identity_pool_provider" "visual_tests" {
  for_each = local.visual_identities

  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = each.value.account_id
  display_name                       = "Studio visual tests ${each.key}"
  description                        = "Trust Studio ${each.key} workflow events for Drive visual-test storage."
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
    "assertion.repository_owner_id == '${local.studio_github.owner_id}'",
    "assertion.repository_id == '${local.studio_github.repository_id}'",
    "assertion.repository == '${local.studio_github.repository}'",
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

output "studio_visual_tests" {
  description = "Keyless Drive identities; Workspace administrators configure Shared Drive membership separately."
  value = {
    oauth_scope = "https://www.googleapis.com/auth/drive"
    identities = { for name, account in google_service_account.visual_tests : name => {
      service_account   = account.email
      identity_provider = google_iam_workload_identity_pool_provider.visual_tests[name].name
    } }
    shared_drive_roles = {
      references = { ci = "reader", maintenance = "organizer" }
      results    = { ci = "writer", maintenance = "organizer" }
    }
  }

  depends_on = [
    google_project_service.management["drive.googleapis.com"],
    google_service_account_iam_member.visual_tests,
  ]
}
