mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email = "agora-json-keys-private@agora-private-test.iam.gserviceaccount.com"
      name  = "projects/agora-private-test/serviceAccounts/agora-json-keys-private@agora-private-test.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_monitoring_notification_channel" {
    defaults = { name = "projects/123456789012/notificationChannels/123456789" }
  }
}

variables {
  state_bucket           = "agora-management-test-123456789012-tofu-state"
  project_id             = "agora-private-test"
  service                = "json-keys"
  zone                   = "private"
  management_project_id  = "agora-management-test"
  region                 = "europe-west1"
  operations_alert_email = "operations@example.test"
}

run "private_json_keys_prerequisites" {
  command = plan

  assert {
    condition     = length(google_monitoring_alert_policy.api_error_rate) == 0
    error_message = "Private gRPC must not enroll a REST alert."
  }

  assert {
    condition = (
      google_service_account.runtime.account_id == "agora-json-keys-private" &&
      toset(keys(google_secret_manager_secret_iam_member.runtime)) == toset([
        "production-json-keys-postgres-password", "production-json-keys-app-master-key",
      ]) &&
      alltrue([for binding in google_secret_manager_secret_iam_member.runtime :
        binding.project == var.management_project_id &&
        binding.member == "serviceAccount:${google_service_account.runtime.email}" &&
        binding.role == "roles/secretmanager.secretAccessor"
      ])
    )
    error_message = "Only this private service identity may receive its database and signing credentials."
  }

  assert {
    condition = (
      { for key, repository in google_artifact_registry_repository.images : key => repository.repository_id } == {
        agora-production = "agora-json-keys-private-production"
        agora-tooling    = "agora-json-keys-private-tooling"
      } &&
      google_artifact_registry_repository_iam_member.release.member == "serviceAccount:infra-json-keys-private@agora-private-test.iam.gserviceaccount.com" &&
      google_artifact_registry_repository_iam_member.release.repository == "agora-json-keys-private-production" &&
      google_artifact_registry_repository_iam_member.release.role == "roles/artifactregistry.writer" &&
      alltrue([for repository in google_artifact_registry_repository.images :
        repository.project == var.project_id && repository.docker_config[0].immutable_tags &&
        repository.deletion_policy == "PREVENT" && repository.cleanup_policy_dry_run && length(repository.cleanup_policies) == 0
      ])
    )
    error_message = "Application publication must be scoped to protected service/zone repositories."
  }

  assert {
    condition = (
      output.runtime.schema_version == 2 && output.runtime.zone == "private" &&
      output.runtime.repositories["agora-production"] == "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-production" &&
      google_storage_managed_folder.coordinates.name == "foundation/coordinates/workloads/production/private/agora-private-test/json-keys/" &&
      google_storage_managed_folder_iam_member.coordinate_reader.member == google_artifact_registry_repository_iam_member.release.member &&
      google_storage_managed_folder_iam_member.coordinate_reader.role == "roles/storage.objectViewer" &&
      google_storage_managed_folder.coordinates.deletion_policy == "PREVENT" &&
      !google_storage_managed_folder.coordinates.force_destroy &&
      google_storage_bucket_object.coordinates.content == jsonencode({
        schema_version = 2, scope = "workloads/production/private/agora-private-test/json-keys",
        runtime        = output.runtime, database = null, rollout = null,
      }) &&
      google_storage_bucket_object.coordinates.deletion_policy == "ABANDON" &&
      output.coordinates.schema_version == 2 &&
      output.coordinates.object == "foundation/coordinates/workloads/production/private/agora-private-test/json-keys/${sha256(google_storage_bucket_object.coordinates.content)}.json" &&
      output.coordinates.sha256 == sha256(google_storage_bucket_object.coordinates.content)
    )
    error_message = "Published references must bind the exact service/zone, schema and retained content hash."
  }

  assert {
    condition = (
      length(google_secret_manager_secret_iam_member.foundation_job_metadata) == 0 &&
      length(google_compute_disk.database) == 0 && length(google_compute_instance.repository) == 0 &&
      length(module.job_access) == 0 &&
      output.database == null && output.pgbackrest_repository == null && output.native_bringup == null
    )
    error_message = "Shared prerequisites must not claim existing hosts or enable jobs or backup maintenance."
  }
}

run "public_api_json_keys_prerequisites" {
  command = plan
  variables {
    project_id = "agora-public-api-test"
    zone       = "public-api"
  }
  override_resource {
    target = google_service_account.runtime
    values = {
      email = "agora-json-keys-api@agora-public-api-test.iam.gserviceaccount.com"
      name  = "projects/agora-public-api-test/serviceAccounts/agora-json-keys-api@agora-public-api-test.iam.gserviceaccount.com"
    }
  }

  assert {
    condition = (
      google_monitoring_alert_policy.api_error_rate[0].project == var.project_id &&
      google_monitoring_alert_policy.api_error_rate[0].conditions[0].condition_threshold[0].filter == "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"agora-json-keys-rest\" AND resource.label.location = \"europe-west1\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.label.response_code_class = \"5xx\""
    )
    error_message = "JSON Keys REST monitoring must not select its private gRPC sibling or Authentication."
  }
  assert {
    condition = (
      google_service_account.runtime.account_id == "agora-json-keys-api" &&
      toset(keys(google_secret_manager_secret_iam_member.runtime)) == toset(["production-json-keys-postgres-password"]) &&
      google_secret_manager_secret_iam_member.runtime["production-json-keys-postgres-password"].member == "serviceAccount:agora-json-keys-api@agora-public-api-test.iam.gserviceaccount.com" &&
      toset(keys(google_secret_manager_secret_iam_member.foundation_job_metadata)) == toset(["production-json-keys-postgres-password"]) &&
      google_secret_manager_secret_iam_member.foundation_job_metadata["production-json-keys-postgres-password"].project == var.management_project_id &&
      google_secret_manager_secret_iam_member.foundation_job_metadata["production-json-keys-postgres-password"].role == "roles/secretmanager.viewer" &&
      google_secret_manager_secret_iam_member.foundation_job_metadata["production-json-keys-postgres-password"].member == "serviceAccount:infra-foundation@agora-management-test.iam.gserviceaccount.com"
    )
    error_message = "JSON Keys REST receives only its database credential; foundation may inspect only that credential's metadata."
  }
  assert {
    condition = (
      google_artifact_registry_repository.images["agora-production"].repository_id == "agora-json-keys-api-production" &&
      google_artifact_registry_repository.images["agora-tooling"].repository_id == "agora-json-keys-api-tooling" &&
      google_artifact_registry_repository_iam_member.release.member == "serviceAccount:infra-json-keys-api@agora-public-api-test.iam.gserviceaccount.com" &&
      google_storage_managed_folder_iam_member.coordinate_reader.member == google_artifact_registry_repository_iam_member.release.member &&
      google_storage_managed_folder.coordinates.name == "foundation/coordinates/workloads/production/public-api/agora-public-api-test/json-keys/" &&
      jsondecode(google_storage_bucket_object.coordinates.content).scope == "workloads/production/public-api/agora-public-api-test/json-keys" &&
      output.runtime.zone == "public-api" && output.runtime.schema_version == 2 &&
      length(module.job_access) == 0 && output.database == null
    )
    error_message = "Public API resources and coordinates must use their own identity and namespace without a host or job writer."
  }
}

run "private_authentication_prerequisites" {
  command = plan
  variables { service = "authentication" }
  override_resource {
    target = google_service_account.runtime
    values = {
      email = "agora-authentication-private@agora-private-test.iam.gserviceaccount.com"
      name  = "projects/agora-private-test/serviceAccounts/agora-authentication-private@agora-private-test.iam.gserviceaccount.com"
    }
  }
  assert {
    condition = (
      google_service_account.runtime.account_id == "agora-authentication-private" &&
      toset(keys(google_secret_manager_secret_iam_member.runtime)) == toset([
        "production-authentication-postgres-password", "production-authentication-smtp-sender-password",
      ]) &&
      alltrue([for binding in google_secret_manager_secret_iam_member.runtime :
        binding.member == "serviceAccount:agora-authentication-private@agora-private-test.iam.gserviceaccount.com"
      ]) &&
      google_artifact_registry_repository.images["agora-production"].repository_id == "agora-authentication-private-production" &&
      google_artifact_registry_repository.images["agora-tooling"].repository_id == "agora-authentication-private-tooling" &&
      google_artifact_registry_repository_iam_member.release.member == "serviceAccount:infra-authentication-private@agora-private-test.iam.gserviceaccount.com" &&
      google_storage_managed_folder.coordinates.name == "foundation/coordinates/workloads/production/private/agora-private-test/authentication/" &&
      google_storage_managed_folder_iam_member.coordinate_reader.member == google_artifact_registry_repository_iam_member.release.member
    )
    error_message = "Authentication must coexist in the private project without JSON Keys credentials, repositories or coordinate grants."
  }
}

run "public_api_authentication_prerequisites" {
  command = plan
  variables {
    project_id = "agora-public-api-test"
    service    = "authentication"
    zone       = "public-api"
  }
  override_resource {
    target = google_service_account.runtime
    values = {
      email = "agora-authentication-api@agora-public-api-test.iam.gserviceaccount.com"
      name  = "projects/agora-public-api-test/serviceAccounts/agora-authentication-api@agora-public-api-test.iam.gserviceaccount.com"
    }
  }
  assert {
    condition = (
      toset(keys(google_secret_manager_secret_iam_member.foundation_job_metadata)) == toset([
        "production-authentication-postgres-password", "production-authentication-smtp-sender-password",
      ]) &&
      alltrue([for binding in google_secret_manager_secret_iam_member.foundation_job_metadata :
        binding.project == var.management_project_id &&
        binding.role == "roles/secretmanager.viewer" &&
        binding.member == "serviceAccount:infra-foundation@agora-management-test.iam.gserviceaccount.com"
      ])
    )
    error_message = "Foundation may check enabled versions of only Authentication's API secrets, without payload access."
  }
  assert {
    condition = (
      alltrue([for binding in google_project_iam_member.runtime_telemetry :
        binding.project == var.project_id && binding.member == "serviceAccount:agora-authentication-api@agora-public-api-test.iam.gserviceaccount.com"
      ]) &&
      google_monitoring_alert_policy.api_error_rate[0].project == var.project_id &&
      google_monitoring_alert_policy.api_error_rate[0].enabled &&
      google_monitoring_alert_policy.api_error_rate[0].severity == "ERROR" &&
      google_monitoring_alert_policy.api_error_rate[0].combiner == "OR" &&
      toset(google_monitoring_alert_policy.api_error_rate[0].notification_channels) == toset([google_monitoring_notification_channel.operations.name]) &&
      google_monitoring_alert_policy.api_error_rate[0].conditions[0].condition_threshold[0].filter == "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"agora-authentication-rest\" AND resource.label.location = \"europe-west1\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.label.response_code_class = \"5xx\"" &&
      google_monitoring_alert_policy.api_error_rate[0].conditions[0].condition_threshold[0].denominator_filter == "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"agora-authentication-rest\" AND resource.label.location = \"europe-west1\" AND metric.type = \"run.googleapis.com/request_count\"" &&
      google_monitoring_alert_policy.api_error_rate[0].conditions[0].condition_threshold[0].threshold_value == 0.10 &&
      google_monitoring_alert_policy.api_error_rate[0].conditions[0].condition_threshold[0].duration == "300s" &&
      google_monitoring_alert_policy.api_error_rate[0].conditions[0].condition_threshold[0].comparison == "COMPARISON_GT" &&
      google_monitoring_alert_policy.api_error_rate[0].conditions[0].condition_threshold[0].evaluation_missing_data == "EVALUATION_MISSING_DATA_INACTIVE" &&
      google_monitoring_alert_policy.api_error_rate[0].conditions[0].condition_threshold[0].aggregations == google_monitoring_alert_policy.api_error_rate[0].conditions[0].condition_threshold[0].denominator_aggregations &&
      google_monitoring_alert_policy.api_error_rate[0].conditions[0].condition_threshold[0].aggregations[0].per_series_aligner == "ALIGN_DELTA" &&
      google_monitoring_alert_policy.api_error_rate[0].conditions[0].condition_threshold[0].aggregations[0].cross_series_reducer == "REDUCE_SUM"
    )
    error_message = "Authentication REST must preserve project-local telemetry and its five-minute 10% 5xx alert using the existing operations channel."
  }
  assert {
    condition = (
      google_service_account.runtime.account_id == "agora-authentication-api" &&
      length(google_service_account.runtime.account_id) <= 30 &&
      toset(keys(google_secret_manager_secret_iam_member.runtime)) == toset([
        "production-authentication-postgres-password", "production-authentication-smtp-sender-password",
      ]) &&
      alltrue([for binding in google_secret_manager_secret_iam_member.runtime :
        binding.member == "serviceAccount:agora-authentication-api@agora-public-api-test.iam.gserviceaccount.com"
      ]) &&
      google_artifact_registry_repository.images["agora-production"].repository_id == "agora-authentication-api-production" &&
      google_artifact_registry_repository.images["agora-tooling"].repository_id == "agora-authentication-api-tooling" &&
      google_artifact_registry_repository_iam_member.release.member == "serviceAccount:infra-authentication-api@agora-public-api-test.iam.gserviceaccount.com" &&
      google_storage_managed_folder.coordinates.name == "foundation/coordinates/workloads/production/public-api/agora-public-api-test/authentication/" &&
      google_storage_managed_folder_iam_member.coordinate_reader.member == google_artifact_registry_repository_iam_member.release.member &&
      output.runtime.zone == "public-api" && output.runtime.schema_version == 2
    )
    error_message = "Authentication API must preserve only its service credentials with distinct valid identities and custody."
  }
}

run "reject_platform_zone" {
  command = plan
  variables { zone = "public" }
  expect_failures = [var.zone]
}

run "reject_unknown_zone" {
  command = plan
  variables { zone = "" }
  expect_failures = [var.zone]
}

run "reject_shared_job_activation" {
  command = plan
  variables { manage_job_access = true }
  expect_failures = [google_service_account.runtime]
}

run "reject_shared_database" {
  command = plan
  variables {
    database = {
      zone       = "europe-west1-b"
      subnetwork = "projects/agora-network-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
      cos_image  = "projects/cos-cloud/global/images/cos-129-19506-448-53"
    }
  }
  expect_failures = [google_service_account.runtime]
}
