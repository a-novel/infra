mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = { email = "application@agora-json-keys-test.iam.gserviceaccount.com" }
  }
  mock_resource "google_monitoring_notification_channel" {
    defaults = { name = "projects/123456789012/notificationChannels/123456789" }
  }
}

variables {
  project_id             = "agora-json-keys-test"
  service                = "json-keys"
  management_project_id  = "agora-management-test"
  region                 = "europe-west1"
  operations_alert_email = "operations@example.test"
}

run "isolated_application_assets" {
  command = plan
  module { source = "../../../modules/service-foundation" }

  assert {
    condition     = [google_service_account.runtime.project, google_service_account.runtime.account_id] == [var.project_id, "agora-json-keys"]
    error_message = "The application identity must belong to its dedicated service project."
  }

  assert {
    condition = { for secret, binding in google_secret_manager_secret_iam_member.runtime : secret => [binding.project, binding.role, binding.member] } == {
      for secret in ["production-json-keys-postgres-password", "production-json-keys-app-master-key"] : secret =>
      [var.management_project_id, "roles/secretmanager.secretAccessor", "serviceAccount:${google_service_account.runtime.email}"]
    }
    error_message = "Grant only this application's two secret containers to its runtime."
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
}

run "authentication_runtime_contract" {
  command = plan
  module { source = "../../../modules/service-foundation" }
  variables {
    project_id = "agora-authentication-test"
    service    = "authentication"
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
}

run "reject_unknown_runtime_contract" {
  command = plan
  module { source = "../../../modules/service-foundation" }
  variables { service = "unknown" }
  expect_failures = [var.service]
}

run "reject_management_as_workload" {
  command = plan
  module { source = "../../../modules/service-foundation" }
  variables { project_id = "agora-management-test" }
  expect_failures = [var.management_project_id]
}
