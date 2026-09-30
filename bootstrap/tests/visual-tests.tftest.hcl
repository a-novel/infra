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

run "keeps_the_latest_master_batch_until_replaced" {
  command = plan

  assert {
    condition = (
      google_storage_bucket.visual_baselines.versioning[0].enabled &&
      length(google_storage_bucket.visual_baselines.lifecycle_rule) == 1 &&
      one(one(google_storage_bucket.visual_baselines.lifecycle_rule).action).type == "Delete" &&
      one(one(google_storage_bucket.visual_baselines.lifecycle_rule).condition).with_state == "ARCHIVED" &&
      one(one(google_storage_bucket.visual_baselines.lifecycle_rule).condition).days_since_noncurrent_time == 7
    )
    error_message = "Only superseded generations may expire, seven days after replacement; the live master batch must never age out."
  }

  assert {
    condition = (
      !google_storage_bucket.visual_reports.versioning[0].enabled &&
      length(google_storage_bucket.visual_reports.lifecycle_rule) == 1 &&
      one(one(google_storage_bucket.visual_reports.lifecycle_rule).action).type == "Delete" &&
      one(one(google_storage_bucket.visual_reports.lifecycle_rule).condition).age == 7
    )
    error_message = "Temporary run evidence must expire after seven days without accumulating versions."
  }

  assert {
    condition = alltrue([for bucket in [google_storage_bucket.visual_baselines, google_storage_bucket.visual_reports] :
      bucket.location == "europe-west1" && bucket.storage_class == "STANDARD" &&
      bucket.uniform_bucket_level_access && bucket.public_access_prevention == "enforced" &&
      !bucket.force_destroy && bucket.soft_delete_policy[0].retention_duration_seconds == 0
    ])
    error_message = "Visual evidence needs private regional Standard storage, protected bucket deletion and no extra soft-delete retention."
  }

  assert {
    condition = (
      output.studio_visual_tests.baseline_object == "platform-studio/master/batch.tar" &&
      output.studio_visual_tests.reports_prefix == "platform-studio/runs/" &&
      output.studio_visual_tests.baseline_bucket == "agora-management-test-123456789012-visual-baselines" &&
      output.studio_visual_tests.reports_bucket == "agora-management-test-123456789012-visual-reports"
    )
    error_message = "Consumers need a single atomically replaced master archive in a bucket separate from expiring reports."
  }
}

run "limits_candidate_jobs_to_reading_baseline_and_creating_reports" {
  command = plan

  assert {
    condition = (
      google_storage_bucket_iam_member.visual_report_creator.bucket == google_storage_bucket.visual_reports.name &&
      google_storage_bucket_iam_member.visual_report_creator.role == "roles/storage.objectCreator" &&
      google_storage_bucket_iam_member.visual_report_creator.member == "serviceAccount:${google_service_account.visual_tests["ci"].email}" &&
      one(google_storage_bucket_iam_member.visual_report_creator.condition).expression == "resource.type == 'storage.googleapis.com/Object' && resource.name.startsWith('projects/_/buckets/agora-management-test-123456789012-visual-reports/objects/platform-studio/runs/')" &&
      google_storage_bucket_iam_member.visual_baseline_reader.bucket == google_storage_bucket.visual_baselines.name &&
      google_storage_bucket_iam_member.visual_baseline_reader.role == "roles/storage.objectViewer" &&
      google_storage_bucket_iam_member.visual_baseline_reader.member == google_storage_bucket_iam_member.visual_report_creator.member &&
      one(google_storage_bucket_iam_member.visual_baseline_reader.condition).expression == "resource.type == 'storage.googleapis.com/Object' && resource.name == 'projects/_/buckets/agora-management-test-123456789012-visual-baselines/objects/platform-studio/master/batch.tar'"
    )
    error_message = "Candidate jobs may create Studio reports and read only the exact master archive; no overwrite or delete grant is allowed."
  }

  assert {
    condition = (
      google_storage_bucket_iam_member.visual_baseline_publisher.bucket == google_storage_bucket.visual_baselines.name &&
      google_storage_bucket_iam_member.visual_baseline_publisher.role == "roles/storage.objectAdmin" &&
      google_storage_bucket_iam_member.visual_baseline_publisher.member == "serviceAccount:${google_service_account.visual_tests["master"].email}" &&
      one(google_storage_bucket_iam_member.visual_baseline_publisher.condition).expression == one(google_storage_bucket_iam_member.visual_baseline_reader.condition).expression &&
      google_service_account.visual_tests["master"].account_id != google_service_account.visual_tests["ci"].account_id
    )
    error_message = "Only the separate master identity may replace the exact baseline archive."
  }

  assert {
    condition = alltrue([for key in ["visual-baselines", "visual-reports"] :
      google_storage_bucket_iam_member.foundation_admin[key].bucket == local.management_buckets[key] &&
      google_storage_bucket_iam_member.operator_admin["group:infra-operators@example.com:${key}"].bucket == local.management_buckets[key]
      ]) && alltrue([for binding in google_project_iam_member.automation :
      !contains([google_storage_bucket_iam_member.visual_baseline_reader.member, google_storage_bucket_iam_member.visual_baseline_publisher.member], binding.member)
    ])
    error_message = "Existing operators administer the buckets; visual identities must not inherit project-wide automation roles."
  }
}

run "separates_master_push_authority_from_branch_builds" {
  command = plan

  assert {
    condition = alltrue([for name, provider in google_iam_workload_identity_pool_provider.visual_tests :
      provider.attribute_condition == join(" && ", [
        "assertion.repository_owner_id == '131281268'",
        "assertion.repository_id == '1338436652'",
        "assertion.repository == 'a-novel/platform-studio'",
        "assertion.workflow_ref == 'a-novel/platform-studio/.github/workflows/main.yaml@' + assertion.ref",
        name == "master" ? "assertion.ref == 'refs/heads/master' && assertion.event_name == 'push'" : "assertion.ref.startsWith('refs/heads/') && assertion.event_name in ['push', 'merge_group']",
      ]) &&
      provider.oidc[0].issuer_uri == "https://token.actions.githubusercontent.com" &&
      provider.oidc[0].allowed_audiences == null &&
      provider.attribute_mapping["attribute.trust_boundary"] == "'studio-visual-${name}'" &&
      provider.deletion_policy == "PREVENT"
    ])
    error_message = "Federation must reject tags, PR events, other repositories/workflows and non-master baseline publishers."
  }

  assert {
    condition = (
      toset(keys(google_service_account.visual_tests)) == toset(["ci", "master"]) &&
      alltrue([for name, binding in google_service_account_iam_member.visual_tests :
        binding.service_account_id == google_service_account.visual_tests[name].name &&
        google_service_account.visual_tests[name].account_id == "studio-visual-${name}" &&
        binding.role == "roles/iam.workloadIdentityUser" &&
        binding.member == "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/attribute.trust_boundary/studio-visual-${name}"
      ])
    )
    error_message = "Each provider may impersonate only its dedicated account, with a constant boundary distinct from infra automation."
  }
}
