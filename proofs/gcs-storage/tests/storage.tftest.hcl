mock_provider "google" {}

variables {
  project_id        = "a-novel-gcs-proof-fixture"
  service           = "json-keys"
  retention_seconds = 600
}

run "storage_custody" {
  command = plan

  assert {
    condition = { for name, bucket in google_storage_bucket.trial : name => {
      project       = bucket.project, name = bucket.name, public = bucket.public_access_prevention,
      uniform       = bucket.uniform_bucket_level_access, versions = bucket.versioning[0].enabled,
      retention     = bucket.retention_policy[0].retention_period, locked = bucket.retention_policy[0].is_locked,
      soft_delete   = bucket.soft_delete_policy[0].retention_duration_seconds,
      force_destroy = bucket.force_destroy, lifecycle = length(bucket.lifecycle_rule),
      } } == { for name in [var.service, "peer"] : name => {
      project     = var.project_id, name = "${var.project_id}-${name}", public = "enforced",
      uniform     = true, versions = true, retention = "600", locked = false,
      soft_delete = 604800, force_destroy = false, lifecycle = 0,
    } }
    error_message = "Keep the synthetic buckets private, versioned, recoverable and free of automatic deletion or irreversible locks."
  }

  assert {
    condition = { for name, role in google_project_iam_custom_role.trial : name => toset(role.permissions) } == {
      writer   = toset(["storage.objects.create", "storage.objects.get", "storage.objects.list", "storage.objects.delete"])
      recovery = toset(["storage.objects.create", "storage.objects.get", "storage.objects.list", "storage.objects.restore"])
    }
    error_message = "Writer and recovery have distinct object-only capabilities; neither owns bucket policy."
  }

  assert {
    condition = alltrue([for name, binding in google_storage_bucket_iam_member.trial :
      binding.bucket == google_storage_bucket.trial[var.service].name &&
      binding.role == google_project_iam_custom_role.trial[name].name &&
      binding.member == "serviceAccount:${google_service_account.trial[name].email}"
    ]) && length(google_storage_bucket_iam_member.trial) == 2
    error_message = "Only the selected bucket grants either trial identity access; the peer remains a denial target."
  }
}

run "reject_production" {
  command = plan
  variables { project_id = "a-novel-production-prod" }
  expect_failures = [var.project_id]
}

run "reject_unbounded_retention" {
  command = plan
  variables { retention_seconds = 604800 }
  expect_failures = [var.retention_seconds]
}
