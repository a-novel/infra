mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email = "agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com"
      name  = "projects/agora-json-keys-test/serviceAccounts/agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_monitoring_notification_channel" {
    defaults = { name = "projects/123456789012/notificationChannels/123456789" }
  }
}

variables {
  state_bucket           = "agora-management-test-123456789012-tofu-state"
  project_id             = "agora-json-keys-test"
  service                = "json-keys"
  management_project_id  = "agora-management-test"
  region                 = "europe-west1"
  operations_alert_email = "operations@example.test"
}

run "isolated_application_assets" {
  command = plan

  assert {
    condition = (
      toset(keys(google_project_iam_member.runtime_telemetry)) == toset(["roles/telemetry.writer", "roles/serviceusage.serviceUsageConsumer"]) &&
      alltrue([for role, binding in google_project_iam_member.runtime_telemetry :
        binding.project == var.project_id && binding.role == role &&
        binding.member == "serviceAccount:${google_service_account.runtime.email}"
      ]) &&
      length(google_monitoring_alert_policy.api_error_rate) == 0
    )
    error_message = "Runtime telemetry must use only its project and identity; dedicated scope must not enroll a public API alert."
  }

  assert {
    condition     = [google_service_account.runtime.project, google_service_account.runtime.account_id] == [var.project_id, "agora-json-keys"]
    error_message = "The application identity must belong to its dedicated service project."
  }

  assert {
    condition = [google_service_account_iam_member.foundation_runtime.service_account_id,
      google_service_account_iam_member.foundation_runtime.role,
      google_service_account_iam_member.foundation_runtime.member] == [
      google_service_account.runtime.name, "roles/iam.serviceAccountUser",
      "serviceAccount:infra-foundation@agora-management-test.iam.gserviceaccount.com",
    ]
    error_message = "Protected bootstrap may attach only the owned application identity."
  }

  assert {
    condition = { for secret, binding in google_secret_manager_secret_iam_member.runtime : secret => [binding.project, binding.role, binding.member] } == {
      for secret in ["production-json-keys-postgres-password", "production-json-keys-app-master-key"] : secret =>
      [var.management_project_id, "roles/secretmanager.secretAccessor", "serviceAccount:${google_service_account.runtime.email}"]
    }
    error_message = "Grant only this application's two secret containers to its runtime."
  }

  assert {
    condition = { for secret, binding in google_secret_manager_secret_iam_member.foundation_job_metadata : secret => [binding.project, binding.secret_id, binding.role, binding.member] } == {
      for secret in ["production-json-keys-postgres-password", "production-json-keys-app-master-key"] : secret =>
      [var.management_project_id, secret, "roles/secretmanager.viewer", "serviceAccount:infra-foundation@agora-management-test.iam.gserviceaccount.com"]
    }
    error_message = "Bootstrap may inspect only JSON Keys job-secret metadata, without payload or version-mutation authority."
  }

  assert {
    condition = { for name, repository in google_artifact_registry_repository.images : name => {
      project   = repository.project, region = repository.location, format = repository.format, mode = repository.mode,
      immutable = repository.docker_config[0].immutable_tags, deletion = repository.deletion_policy,
      cleanup   = length(repository.cleanup_policies), dry_run = repository.cleanup_policy_dry_run,
      } } == { for name in ["agora-production", "agora-tooling"] : name => {
      project   = var.project_id, region = var.region, format = "DOCKER", mode = "STANDARD_REPOSITORY",
      immutable = true, deletion = "PREVENT", cleanup = 0, dry_run = true,
    } }
    error_message = "Keep both regional image stores immutable, protected from deletion and free of age-based cleanup."
  }

  assert {
    condition = [google_artifact_registry_repository_iam_member.release.project,
      google_artifact_registry_repository_iam_member.release.repository,
      google_artifact_registry_repository_iam_member.release.role,
      google_artifact_registry_repository_iam_member.release.member] == [
      var.project_id, "agora-production", "roles/artifactregistry.writer",
      "serviceAccount:infra-release@${var.project_id}.iam.gserviceaccount.com",
    ]
    error_message = "Routine release can publish only application images; verifier custody stays separate."
  }

  assert {
    condition = { for name, binding in google_artifact_registry_repository_iam_member.recovery : name => [binding.project, binding.repository, binding.role, binding.member] } == {
      for name in ["agora-production", "agora-tooling"] : name =>
      [var.project_id, name, "roles/artifactregistry.reader", "serviceAccount:infra-recovery@${var.management_project_id}.iam.gserviceaccount.com"]
    }
    error_message = "Recovery reads retained images without publication or deletion authority."
  }

  assert {
    condition = {
      project      = google_monitoring_notification_channel.operations.project
      type         = google_monitoring_notification_channel.operations.type
      enabled      = google_monitoring_notification_channel.operations.enabled
      email        = google_monitoring_notification_channel.operations.labels.email_address
      deletion     = google_monitoring_notification_channel.operations.deletion_policy
      force_delete = google_monitoring_notification_channel.operations.force_delete
      } == {
      project  = var.project_id, type = "email", enabled = true, email = var.operations_alert_email,
      deletion = "PREVENT", force_delete = false,
    }
    error_message = "Keep the selected service's monitored channel enabled and protected from deletion."
  }

  assert {
    condition = output.runtime == {
      schema_version        = 1
      project_id            = var.project_id
      service               = var.service
      region                = var.region
      service_account       = google_service_account.runtime.email
      notification_channels = toset(["projects/${var.project_id}/notificationChannels/123456789"])
      repositories          = { for name in ["agora-production", "agora-tooling"] : name => "${var.region}-docker.pkg.dev/${var.project_id}/${name}" }
    }
    error_message = "Publish only the selected service's runtime, registry and operations coordinates."
  }

  assert {
    condition = {
      bucket  = google_storage_managed_folder.coordinates.bucket
      prefix  = google_storage_managed_folder.coordinates.name
      destroy = google_storage_managed_folder.coordinates.force_destroy
      policy  = google_storage_managed_folder.coordinates.deletion_policy
      reader = [google_storage_managed_folder_iam_member.coordinate_reader.bucket,
        google_storage_managed_folder_iam_member.coordinate_reader.managed_folder,
        google_storage_managed_folder_iam_member.coordinate_reader.role,
      google_storage_managed_folder_iam_member.coordinate_reader.member]
      } == {
      bucket = var.state_bucket, prefix = "foundation/coordinates/agora-json-keys-test/", destroy = false, policy = "PREVENT"
      reader = [var.state_bucket, "foundation/coordinates/agora-json-keys-test/", "roles/storage.objectViewer",
      "serviceAccount:infra-release@agora-json-keys-test.iam.gserviceaccount.com"]
    }
    error_message = "Only the selected release may read its protected coordinate folder, outside state and release-writable paths."
  }

  assert {
    condition = google_storage_bucket_object.coordinates.content == jsonencode({
      schema_version = 1, runtime = output.runtime, database = null, rollout = null,
      }) && [google_storage_bucket_object.coordinates.deletion_policy,
      google_storage_bucket_object.coordinates.content_type,
    google_storage_bucket_object.coordinates.cache_control] == ["ABANDON", "application/json", "private, no-store"]
    error_message = "Publish only the versioned contract and retain superseded snapshots without exposing private inputs."
  }

  assert {
    condition = output.coordinates == {
      schema_version = 1
      bucket         = var.state_bucket
      object         = "foundation/coordinates/agora-json-keys-test/${sha256(google_storage_bucket_object.coordinates.content)}.json"
      generation     = google_storage_bucket_object.coordinates.generation
      sha256         = sha256(google_storage_bucket_object.coordinates.content)
    }
    error_message = "The approved reference must bind exact serialized bytes, project namespace and native generation."
  }
}

run "authentication_runtime_contract" {
  command = plan
  variables {
    project_id        = "agora-authentication-test"
    service           = "authentication"
    manage_job_access = true
  }

  override_resource {
    target = google_service_account.runtime
    values = {
      email = "agora-authentication@agora-authentication-test.iam.gserviceaccount.com"
      name  = "projects/agora-authentication-test/serviceAccounts/agora-authentication@agora-authentication-test.iam.gserviceaccount.com"
    }
  }

  assert {
    condition = (
      google_service_account.runtime.project == var.project_id &&
      google_service_account.runtime.account_id == "agora-authentication" &&
      toset(keys(google_secret_manager_secret_iam_member.runtime)) == toset([
        "production-authentication-postgres-password", "production-authentication-smtp-sender-password",
      ])
    )
    error_message = "Authentication must not receive the initializer password, backup credentials or JSON Keys secrets."
  }

  assert {
    condition = { for secret, binding in google_secret_manager_secret_iam_member.foundation_job_metadata : secret => [binding.project, binding.secret_id, binding.role, binding.member] } == {
      production-authentication-postgres-password = [var.management_project_id, "production-authentication-postgres-password",
      "roles/secretmanager.viewer", "serviceAccount:infra-foundation@agora-management-test.iam.gserviceaccount.com"]
    }
    error_message = "Authentication bootstrap needs only PostgreSQL metadata; SMTP, initializer, backup and peer secrets remain outside the grant."
  }

  assert {
    condition     = output.runtime.service_account == "agora-authentication@agora-authentication-test.iam.gserviceaccount.com"
    error_message = "Authentication must retain its own runtime identity."
  }

  assert {
    condition = (google_service_account_iam_member.foundation_runtime.service_account_id ==
    "projects/agora-authentication-test/serviceAccounts/agora-authentication@agora-authentication-test.iam.gserviceaccount.com")
    error_message = "Authentication bootstrap must attach its own runtime account."
  }

  assert {
    condition = google_storage_bucket_object.coordinates.content == jsonencode({
      schema_version = 1, runtime = output.runtime, database = null, rollout = null,
      }) && [google_storage_managed_folder.coordinates.name, google_storage_managed_folder_iam_member.coordinate_reader.member] == [
      "foundation/coordinates/agora-authentication-test/", "serviceAccount:infra-release@agora-authentication-test.iam.gserviceaccount.com",
    ]
    error_message = "Authentication's reader and publication must not reuse JSON Keys coordinates."
  }
}


run "reject_foreign_state_bucket" {
  command = plan
  variables { state_bucket = "another-management-123456789012-tofu-state" }
  expect_failures = [var.state_bucket]
}

run "reject_unknown_runtime_contract" {
  command = plan
  variables { service = "unknown" }
  expect_failures = [var.service]
}

run "reject_management_as_workload" {
  command = plan
  variables { project_id = "agora-management-test" }
  expect_failures = [var.management_project_id]
}
