mock_provider "google" {
  mock_data "google_project" { defaults = { number = "123456789012" } }
  mock_resource "google_service_account" {
    defaults = {
      email = "pgbr-json-keys-recovery@agora-management-test.iam.gserviceaccount.com"
      name  = "projects/agora-management-test/serviceAccounts/pgbr-json-keys-recovery@agora-management-test.iam.gserviceaccount.com"
    }
  }
}

variables {
  management_project_id = "agora-management-test"
  operator_principals   = ["group:infra-operators@example.com"]
}

run "default_has_no_native_custody" {
  command = plan
  assert {
    condition = alltrue([
      length(google_storage_bucket.pgbackrest) == 0,
      length(google_project_iam_custom_role.pgbackrest) == 0,
      length(google_service_account.pgbackrest_recovery) == 0,
      length(google_storage_bucket_iam_member.pgbackrest_writer) == 0,
      length(google_storage_bucket_iam_member.pgbackrest_recovery) == 0,
      length(local.management_buckets) == 5,
      length(google_secret_manager_secret.application) == 7,
      length(google_secret_manager_secret_iam_member.pgbackrest_tls) == 0,
      output.json_keys_pgbackrest == null,
    ])
    error_message = "Existing inputs must create no native storage, identities or authority."
  }
}

run "explicit_null_has_no_native_custody" {
  command = plan
  variables { json_keys_pgbackrest = null }
  assert {
    condition     = length(local.pgbackrest) == 0 && length(local.pgbackrest_permissions) == 0 && output.json_keys_pgbackrest == null
    error_message = "An explicit null must preserve the disabled default."
  }
}

run "isolated_native_custody" {
  command = plan
  variables { json_keys_pgbackrest = { workload_project_id = "agora-json-keys-test" } }

  assert {
    condition = (
      length(google_secret_manager_secret.application) == 7 &&
      length(google_secret_manager_secret_iam_member.pgbackrest_tls) == 0
    )
    error_message = "Storage custody alone must not create TLS credentials or payload grants."
  }

  assert {
    condition = { for service, bucket in google_storage_bucket.pgbackrest : service => {
      project       = bucket.project
      name          = bucket.name
      location      = bucket.location
      versioned     = bucket.versioning[0].enabled
      retention     = tonumber(bucket.retention_policy[0].retention_period)
      locked        = bucket.retention_policy[0].is_locked
      soft_delete   = bucket.soft_delete_policy[0].retention_duration_seconds
      public        = bucket.public_access_prevention
      uniform       = bucket.uniform_bucket_level_access
      force_destroy = bucket.force_destroy
      age_rules     = length(bucket.lifecycle_rule)
      } } == { "json-keys" = {
      project       = var.management_project_id
      name          = "agora-management-test-123456789012-pgbr-json-keys"
      location      = "EU"
      versioned     = true
      retention     = 604800
      locked        = false
      soft_delete   = 604800
      public        = "enforced"
      uniform       = true
      force_destroy = false
      age_rules     = 0
    } }
    error_message = "The separate management repository needs private, versioned custody and no age-based chain deletion."
  }

  assert {
    condition = { for purpose, role in google_project_iam_custom_role.pgbackrest : purpose => toset(role.permissions) } == {
      writer   = toset(["storage.objects.create", "storage.objects.get", "storage.objects.list", "storage.objects.delete"])
      recovery = toset(["storage.objects.create", "storage.objects.get", "storage.objects.list", "storage.objects.restore"])
    }
    error_message = "Only recovery may repair generations; neither role may change policy and recovery cannot delete."
  }

  assert {
    condition = { for purpose, binding in {
      writer   = google_storage_bucket_iam_member.pgbackrest_writer["json-keys"]
      recovery = google_storage_bucket_iam_member.pgbackrest_recovery["json-keys"]
      } : purpose => {
      bucket = binding.bucket
      role   = binding.role
      member = binding.member
      } } == { for purpose, member in {
      writer   = "serviceAccount:agora-backup-repository@agora-json-keys-test.iam.gserviceaccount.com"
      recovery = "serviceAccount:pgbr-json-keys-recovery@agora-management-test.iam.gserviceaccount.com"
      } : purpose => {
      bucket = google_storage_bucket.pgbackrest["json-keys"].name
      role   = google_project_iam_custom_role.pgbackrest[purpose].name
      member = member
    } }
    error_message = "Bind each exact identity only to its native repository role."
  }

  assert {
    condition = alltrue([
      google_service_account.pgbackrest_recovery["json-keys"].project == var.management_project_id,
      google_service_account.pgbackrest_recovery["json-keys"].disabled,
      google_storage_bucket_iam_member.foundation_admin["pgbackrest-json-keys"].bucket == google_storage_bucket.pgbackrest["json-keys"].name,
      google_storage_bucket.backups.name != google_storage_bucket.pgbackrest["json-keys"].name,
      output.json_keys_pgbackrest.service == "json-keys",
      output.json_keys_pgbackrest.writer == "agora-backup-repository@agora-json-keys-test.iam.gserviceaccount.com",
    ])
    error_message = "Bind only the selected host and disabled recovery identity to native storage, with its existing administrator."
  }
}

run "isolated_tls_credentials" {
  command = plan
  variables {
    json_keys_pgbackrest = { workload_project_id = "agora-json-keys-test", tls_credentials = true }
  }

  assert {
    condition = { for key, binding in google_secret_manager_secret_iam_member.pgbackrest_tls : key => {
      project = binding.project
      secret  = binding.secret_id
      role    = binding.role
      member  = binding.member
      } } == { for key, pair in {
      "ca:agora-database"                  = ["ca", "agora-database"]
      "ca:agora-backup-repository"         = ["ca", "agora-backup-repository"]
      "database:agora-database"            = ["database", "agora-database"]
      "repository:agora-backup-repository" = ["repository", "agora-backup-repository"]
      } : key => {
      project = var.management_project_id
      secret  = "production-json-keys-pgbackrest-${pair[0]}"
      role    = "roles/secretmanager.secretAccessor"
      member  = "serviceAccount:${pair[1]}@agora-json-keys-test.iam.gserviceaccount.com"
    } }
    error_message = "Each host may read its own identity and the public CA bundle only."
  }

  assert {
    condition = (
      length(google_secret_manager_secret.application) == 10 &&
      length(google_secret_manager_secret_iam_member.operator) == 20 &&
      alltrue([for endpoint in ["ca", "database", "repository"] : alltrue([
        google_secret_manager_secret.application["production-json-keys-pgbackrest-${endpoint}"].deletion_protection,
        google_secret_manager_secret.application["production-json-keys-pgbackrest-${endpoint}"].deletion_policy == "PREVENT",
        google_secret_manager_secret.application["production-json-keys-pgbackrest-${endpoint}"].version_destroy_ttl == "2592000s",
      ])])
    )
    error_message = "TLS credentials must inherit the existing operator and delayed-destruction contract."
  }
}

run "reject_management_as_workload" {
  command = plan
  variables { json_keys_pgbackrest = { workload_project_id = "agora-management-test" } }
  expect_failures = [var.json_keys_pgbackrest]
}

run "reject_member_injection" {
  command = plan
  variables { json_keys_pgbackrest = { workload_project_id = "peer.iam.gserviceaccount.com" } }
  expect_failures = [var.json_keys_pgbackrest]
}
