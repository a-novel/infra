locals {
  studio_github = {
    owner_id      = "131281268"
    repository_id = "1338436652"
    repository    = "a-novel/platform-studio"
    workflow      = "a-novel/platform-studio/.github/workflows/main.yaml"
  }
  visual_baseline_object = "platform-studio/master/batch.tar"
  visual_report_prefix   = "platform-studio/runs/"
  visual_identities = {
    ci = {
      account_id = "studio-visual-ci"
      condition  = "assertion.ref.startsWith('refs/heads/') && assertion.event_name in ['push', 'merge_group']"
    }
    master = {
      account_id = "studio-visual-master"
      condition  = "assertion.ref == 'refs/heads/master' && assertion.event_name == 'push'"
    }
  }
}

resource "google_storage_bucket" "visual_reports" {
  name                        = "${local.bucket_name_prefix}-visual-reports"
  location                    = var.region
  storage_class               = "STANDARD"
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = false
  }
  soft_delete_policy {
    retention_duration_seconds = 0
  }
  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 7 }
  }
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["storage.googleapis.com"]]
}

resource "google_storage_bucket" "visual_baselines" {
  name                        = "${local.bucket_name_prefix}-visual-baselines"
  location                    = var.region
  storage_class               = "STANDARD"
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }
  soft_delete_policy {
    retention_duration_seconds = 0
  }
  lifecycle_rule {
    action { type = "Delete" }
    # The latest complete master batch stays live, even through months of inactivity.
    condition {
      with_state                 = "ARCHIVED"
      days_since_noncurrent_time = 7
    }
  }
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["storage.googleapis.com"]]
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
  description                        = "Trust Studio main workflow ${each.key} runs for visual-test storage."
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
    "assertion.workflow_ref == '${local.studio_github.workflow}@' + assertion.ref",
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

resource "google_storage_bucket_iam_member" "visual_report_creator" {
  bucket = google_storage_bucket.visual_reports.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.visual_tests["ci"].email}"

  condition {
    title       = "StudioRunReportsOnly"
    description = "Create unique report objects beneath Studio's run prefix."
    expression  = "resource.type == 'storage.googleapis.com/Object' && resource.name.startsWith('projects/_/buckets/${google_storage_bucket.visual_reports.name}/objects/${local.visual_report_prefix}')"
  }
}

resource "google_storage_bucket_iam_member" "visual_baseline_reader" {
  bucket = google_storage_bucket.visual_baselines.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.visual_tests["ci"].email}"

  condition {
    title       = "StudioMasterBatchOnly"
    description = "Read the complete master baseline by its exact object name."
    expression  = "resource.type == 'storage.googleapis.com/Object' && resource.name == 'projects/_/buckets/${google_storage_bucket.visual_baselines.name}/objects/${local.visual_baseline_object}'"
  }
}

resource "google_storage_bucket_iam_member" "visual_baseline_publisher" {
  bucket = google_storage_bucket.visual_baselines.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.visual_tests["master"].email}"

  condition {
    title       = "StudioMasterBatchOnly"
    description = "Replace the complete master batch atomically at its exact object name."
    expression  = "resource.type == 'storage.googleapis.com/Object' && resource.name == 'projects/_/buckets/${google_storage_bucket.visual_baselines.name}/objects/${local.visual_baseline_object}'"
  }
}

output "studio_visual_tests" {
  description = "Private visual-test storage and keyless CI coordinates; the consumer workflow controls successful master promotion."
  value = {
    reports_bucket  = google_storage_bucket.visual_reports.name
    reports_prefix  = local.visual_report_prefix
    baseline_bucket = google_storage_bucket.visual_baselines.name
    baseline_object = local.visual_baseline_object
    identities = { for name, account in google_service_account.visual_tests : name => {
      service_account   = account.email
      identity_provider = google_iam_workload_identity_pool_provider.visual_tests[name].name
    } }
  }

  depends_on = [
    google_service_account_iam_member.visual_tests,
    google_storage_bucket_iam_member.visual_report_creator,
    google_storage_bucket_iam_member.visual_baseline_reader,
    google_storage_bucket_iam_member.visual_baseline_publisher,
    google_storage_bucket_iam_member.foundation_admin,
    google_storage_bucket_iam_member.operator_admin,
  ]
}
