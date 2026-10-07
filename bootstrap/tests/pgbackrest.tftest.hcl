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
      length(local.management_buckets) == 3,
      length(google_secret_manager_secret.application) == 6,
      length(google_secret_manager_secret_iam_member.pgbackrest_tls) == 0,
      length(output.native_backups) == 0,
    ])
    error_message = "Existing inputs must create no native storage, identities or authority."
  }
}

run "empty_map_has_no_native_custody" {
  command = plan
  variables { native_backups = {} }
  assert {
    condition     = length(local.pgbackrest) == 0 && length(local.pgbackrest_roles) == 0 && length(output.native_backups) == 0
    error_message = "An empty map must preserve the disabled default."
  }
}

run "isolated_native_custody" {
  command = plan
  variables { native_backups = { "json-keys" = { workload_project_id = "agora-json-keys-test", zone = "private" } } }

  assert {
    condition = (
      length(google_secret_manager_secret.application) == 6 &&
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
      "json-keys:writer"   = toset(["storage.objects.create", "storage.objects.get", "storage.objects.list", "storage.objects.delete"])
      "json-keys:recovery" = toset(["storage.objects.create", "storage.objects.get", "storage.objects.list", "storage.objects.restore"])
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
      writer   = "serviceAccount:agora-pgbr-json-keys@agora-json-keys-test.iam.gserviceaccount.com"
      recovery = "serviceAccount:pgbr-json-keys-recovery@agora-management-test.iam.gserviceaccount.com"
      } : purpose => {
      bucket = google_storage_bucket.pgbackrest["json-keys"].name
      role   = google_project_iam_custom_role.pgbackrest["json-keys:${purpose}"].name
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
      output.native_backups["json-keys"].service == "json-keys",
      output.native_backups["json-keys"].writer == "agora-pgbr-json-keys@agora-json-keys-test.iam.gserviceaccount.com",
    ])
    error_message = "Bind only the selected host and disabled recovery identity to native storage, with its existing administrator."
  }
}

run "noncurrent_cleanup_requires_separate_opt_in" {
  command = plan
  variables {
    native_backups = { "json-keys" = { workload_project_id = "agora-json-keys-test", zone = "private", noncurrent_cleanup = true } }
  }

  assert {
    condition = [for rule in google_storage_bucket.pgbackrest["json-keys"].lifecycle_rule : {
      action     = one(rule.action).type
      state      = one(rule.condition).with_state
      days       = one(rule.condition).days_since_noncurrent_time
      age        = coalesce(one(rule.condition).age, 0)
      send_age   = one(rule.condition).send_age_if_zero
      newer      = coalesce(one(rule.condition).num_newer_versions, 0)
      send_newer = coalesce(one(rule.condition).send_num_newer_versions_if_zero, false)
      }] == [{
      action = "Delete", state = "ARCHIVED", days = 7,
      age    = 0, send_age = false, newer = 0, send_newer = false,
    }]
    error_message = "Cleanup must select only seven-day-old noncurrent generations, without age or version-count shortcuts."
  }

  assert {
    condition = alltrue([
      tonumber(google_storage_bucket.pgbackrest["json-keys"].retention_policy[0].retention_period) == 604800,
      google_storage_bucket.pgbackrest["json-keys"].soft_delete_policy[0].retention_duration_seconds == 604800,
    ])
    error_message = "Noncurrent cleanup must preserve minimum retention and soft delete."
  }
}

run "isolated_tls_credentials" {
  command = plan
  variables {
    native_backups = { "json-keys" = { workload_project_id = "agora-json-keys-test", zone = "private", tls_credentials = true } }
  }

  assert {
    condition = { for key, binding in google_secret_manager_secret_iam_member.pgbackrest_tls : key => {
      project = binding.project
      secret  = binding.secret_id
      role    = binding.role
      member  = binding.member
      } } == { for key, pair in {
      "json-keys:ca:agora-json-keys-database"       = ["ca", "agora-json-keys-database"]
      "json-keys:ca:agora-pgbr-json-keys"           = ["ca", "agora-pgbr-json-keys"]
      "json-keys:database:agora-json-keys-database" = ["database", "agora-json-keys-database"]
      "json-keys:repository:agora-pgbr-json-keys"   = ["repository", "agora-pgbr-json-keys"]
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
      length(google_secret_manager_secret.application) == 9 &&
      length(google_secret_manager_secret_iam_member.operator) == 18 &&
      alltrue([for endpoint in ["ca", "database", "repository"] : alltrue([
        google_secret_manager_secret.application["production-json-keys-pgbackrest-${endpoint}"].deletion_protection,
        google_secret_manager_secret.application["production-json-keys-pgbackrest-${endpoint}"].deletion_policy == "PREVENT",
        google_secret_manager_secret.application["production-json-keys-pgbackrest-${endpoint}"].version_destroy_ttl == "2592000s",
      ])])
    )
    error_message = "TLS credentials must inherit the existing operator and delayed-destruction contract."
  }
}

run "shared_private_custody" {
  command = plan
  variables {
    native_backups = { "json-keys" = { workload_project_id = "agora-private-test", zone = "private", tls_credentials = true } }
  }
  assert {
    condition = (
      google_storage_bucket_iam_member.pgbackrest_writer["json-keys"].member == "serviceAccount:agora-pgbr-json-keys@agora-private-test.iam.gserviceaccount.com" &&
      output.native_backups["json-keys"].writer == "agora-pgbr-json-keys@agora-private-test.iam.gserviceaccount.com" &&
      google_service_account.pgbackrest_recovery["json-keys"].disabled &&
      length(google_storage_bucket.pgbackrest["json-keys"].lifecycle_rule) == 0
    )
    error_message = "Shared custody grants only the repository identity write access, with recovery disabled and no automatic cleanup."
  }
  assert {
    condition = { for key, binding in google_secret_manager_secret_iam_member.pgbackrest_tls : key => binding.member } == {
      "json-keys:ca:agora-json-keys-database"       = "serviceAccount:agora-json-keys-database@agora-private-test.iam.gserviceaccount.com"
      "json-keys:ca:agora-pgbr-json-keys"           = "serviceAccount:agora-pgbr-json-keys@agora-private-test.iam.gserviceaccount.com"
      "json-keys:database:agora-json-keys-database" = "serviceAccount:agora-json-keys-database@agora-private-test.iam.gserviceaccount.com"
      "json-keys:repository:agora-pgbr-json-keys"   = "serviceAccount:agora-pgbr-json-keys@agora-private-test.iam.gserviceaccount.com"
    }
    error_message = "Only the existing database and repository identities may read their own TLS identity and the public CA."
  }
}

run "reject_public_custody" {
  command = plan
  variables { native_backups = { "json-keys" = { workload_project_id = "agora-api-test", zone = "public-api" } } }
  expect_failures = [var.native_backups]
}

run "reject_management_as_workload" {
  command = plan
  variables { native_backups = { "json-keys" = { workload_project_id = "agora-management-test", zone = "private" } } }
  expect_failures = [var.native_backups]
}

run "reject_member_injection" {
  command = plan
  variables { native_backups = { "json-keys" = { workload_project_id = "peer.iam.gserviceaccount.com", zone = "private" } } }
  expect_failures = [var.native_backups]
}

run "both_services_have_separate_custody" {
  command = plan
  variables {
    native_backups = {
      json-keys      = { workload_project_id = "agora-private-test", zone = "private", tls_credentials = true }
      authentication = { workload_project_id = "agora-private-test", zone = "private", tls_credentials = true }
    }
  }
  assert {
    condition = alltrue([
      length(google_storage_bucket.pgbackrest) == 2,
      length(google_project_iam_custom_role.pgbackrest) == 4,
      length(google_service_account.pgbackrest_recovery) == 2,
      google_service_account.pgbackrest_recovery["json-keys"].display_name == "JSON Keys native backup recovery",
      length(google_secret_manager_secret_iam_member.pgbackrest_tls) == 8,
      alltrue([for service in keys(var.native_backups) : alltrue([
        google_storage_bucket.pgbackrest[service].name == "agora-management-test-123456789012-pgbr-${service}",
        google_storage_bucket_iam_member.pgbackrest_writer[service].member == "serviceAccount:agora-pgbr-${service}@agora-private-test.iam.gserviceaccount.com",
        google_storage_bucket_iam_member.pgbackrest_writer[service].role == google_project_iam_custom_role.pgbackrest["${service}:writer"].name,
        google_service_account.pgbackrest_recovery[service].account_id == "pgbr-${service}-recovery",
        google_service_account.pgbackrest_recovery[service].disabled,
        google_secret_manager_secret_iam_member.pgbackrest_tls["${service}:repository:agora-pgbr-${service}"].member == "serviceAccount:agora-pgbr-${service}@agora-private-test.iam.gserviceaccount.com",
      ])]),
      alltrue([for service, account in { json-keys = "agora-json-keys-database", authentication = "agora-auth-database" } : alltrue([
        google_secret_manager_secret_iam_member.pgbackrest_tls["${service}:database:${account}"].secret_id == google_secret_manager_secret.application["production-${service}-pgbackrest-database"].secret_id,
        google_secret_manager_secret_iam_member.pgbackrest_tls["${service}:database:${account}"].member == "serviceAccount:${account}@agora-private-test.iam.gserviceaccount.com",
        google_secret_manager_secret_iam_member.pgbackrest_tls["${service}:ca:${account}"].member == "serviceAccount:${account}@agora-private-test.iam.gserviceaccount.com",
      ])]),
    ])
    error_message = "Coexisting services must have separate buckets, recovery identities and exact-service TLS grants."
  }
}
