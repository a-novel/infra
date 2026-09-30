mock_provider "google" {
  mock_data "google_project" { defaults = { number = "123456789012" } }
  mock_resource "google_service_account" {
    defaults = {
      email = "infra-mock@agora-management-test.iam.gserviceaccount.com"
      name  = "projects/agora-management-test/serviceAccounts/infra-mock@agora-management-test.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_iam_workload_identity_pool" {
    defaults = { name = "projects/123456789012/locations/global/workloadIdentityPools/github-actions" }
  }
}

override_resource {
  target = google_service_account.visual_tests
  values = {
    email = "visual-mock@agora-management-test.iam.gserviceaccount.com"
    name  = "projects/agora-management-test/serviceAccounts/visual-mock@agora-management-test.iam.gserviceaccount.com"
  }
}

variables {
  management_project_id = "agora-management-test"
  operator_principals   = ["group:infra-operators@example.com"]
}

run "enables_drive_without_adding_cloud_storage_authority" {
  command = plan

  assert {
    condition = (
      google_project_service.management["drive.googleapis.com"].service == "drive.googleapis.com" &&
      !google_project_service.management["drive.googleapis.com"].disable_on_destroy &&
      length(local.management_buckets) == 3 &&
      output.visual_tests.oauth_scope == "https://www.googleapis.com/auth/drive"
    )
    error_message = "Drive needs its API and OAuth scope; visual tests must not add Cloud Storage buckets."
  }

  assert {
    condition = alltrue([for binding in google_project_iam_member.automation :
      binding.member != "serviceAccount:${google_service_account.visual_tests["studio-ci"].email}" &&
      binding.member != "serviceAccount:${google_service_account.visual_tests["studio-maintenance"].email}"
    ])
    error_message = "Visual identities must not inherit project-wide infrastructure roles."
  }
}

run "exports_separate_candidate_and_maintenance_membership" {
  command = plan

  assert {
    condition = (
      output.visual_tests.ci_folder_roles.references == "reader" &&
      output.visual_tests.maintenance_parent_role == "organizer" &&
      output.visual_tests.ci_folder_roles.results == "writer" &&
      google_service_account.visual_tests["studio-ci"].account_id != google_service_account.visual_tests["studio-maintenance"].account_id
    )
    error_message = "Workspace must grant candidates read-only references; only trusted maintenance may permanently delete batches."
  }
}

run "restricts_maintenance_to_the_trusted_default_branch_workflow" {
  command = plan

  assert {
    condition = alltrue([for name, provider in google_iam_workload_identity_pool_provider.visual_tests :
      provider.attribute_condition == join(" && ", [
        "assertion.repository_owner_id == '131281268'",
        "assertion.repository_id == '1338436652'",
        "assertion.repository == 'a-novel/platform-studio'",
        name == "studio-maintenance" ? "((assertion.workflow_ref == 'a-novel/platform-studio/.github/workflows/main.yaml@refs/heads/master' && assertion.event_name == 'push') || (assertion.workflow_ref == 'a-novel/platform-studio/.github/workflows/visual-tests.yaml@refs/heads/master' && assertion.event_name in ['workflow_run', 'pull_request_target', 'delete', 'schedule']))" : "(assertion.workflow_ref == 'a-novel/platform-studio/.github/workflows/main.yaml@' + assertion.ref)",
        name == "studio-maintenance" ? "assertion.ref == 'refs/heads/master'" : "assertion.ref.startsWith('refs/heads/') && assertion.event_name in ['push', 'merge_group']",
      ]) &&
      provider.oidc[0].issuer_uri == "https://token.actions.githubusercontent.com" &&
      provider.oidc[0].allowed_audiences == null &&
      provider.attribute_mapping["attribute.trust_boundary"] == "'${local.visual_identities[name].account_id}'" &&
      provider.deletion_policy == "PREVENT"
    ])
    error_message = "Only the exact repository and workflow events may federate; maintenance must reject candidate branches and non-push main.yaml events."
  }

  assert {
    condition = (
      toset(keys(google_service_account.visual_tests)) == toset(["studio-ci", "studio-maintenance"]) &&
      alltrue([for name, binding in google_service_account_iam_member.visual_tests :
        binding.service_account_id == google_service_account.visual_tests[name].name &&
        google_service_account.visual_tests[name].account_id == local.visual_identities[name].account_id &&
        binding.role == "roles/iam.workloadIdentityUser" &&
        binding.member == "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/attribute.trust_boundary/${local.visual_identities[name].account_id}"
      ])
    )
    error_message = "Each provider may impersonate only its dedicated account, without keys or domain-wide delegation."
  }
}

run "a_second_platform_gets_distinct_repository_trust_and_folder_coordinates" {
  command = plan
  variables {
    visual_test_platforms = {
      studio  = { repository = "a-novel/platform-studio", repository_id = "1338436652" }
      fixture = { repository = "a-novel/platform-fixture", repository_id = "1234567890" }
    }
  }
  assert {
    condition = (
      length(google_service_account.visual_tests) == 4 &&
      length(google_iam_workload_identity_pool_provider.visual_tests) == 4 &&
      output.visual_tests.platforms.studio.folders.references == "studio/ci/references" &&
      output.visual_tests.platforms.fixture.folders.results == "fixture/ci/results" &&
      alltrue([for name, provider in google_iam_workload_identity_pool_provider.visual_tests :
        strcontains(provider.attribute_condition, "assertion.repository_id == '${local.visual_identities[name].repository_id}'") &&
        strcontains(provider.attribute_condition, "assertion.repository == '${local.visual_identities[name].repository}'") &&
        provider.attribute_mapping["attribute.trust_boundary"] == "'${local.visual_identities[name].account_id}'" &&
        endswith(google_service_account_iam_member.visual_tests[name].member, "/${local.visual_identities[name].account_id}")
      ])
    )
    error_message = "Adding a platform must create separate repository-bound identities and platform folders without copying resources."
  }
}

run "rejects_duplicate_repository_identities" {
  command = plan
  variables {
    visual_test_platforms = {
      studio  = { repository = "a-novel/platform-studio", repository_id = "1338436652" }
      fixture = { repository = "a-novel/platform-fixture", repository_id = "1338436652" }
    }
  }
  expect_failures = [var.visual_test_platforms]
}
