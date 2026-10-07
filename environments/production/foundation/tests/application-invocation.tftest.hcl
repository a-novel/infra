mock_provider "google-beta" {}

mock_provider "google" {
  mock_resource "google_project" {
    defaults = { number = "987654321098" }
  }
  mock_resource "google_service_account" {
    defaults = {
      email = "agora-scheduler-invoker@agora-production-test.iam.gserviceaccount.com"
      name  = "projects/agora-production-test/serviceAccounts/agora-scheduler-invoker@agora-production-test.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_tags_tag_value" {
    defaults = { id = "tagValues/200000000001" }
  }
}

variables {
  import_application_invocation         = false
  management_project_id                 = "agora-management-test"
  workload_project_id                   = "agora-production-test"
  adopt_default_network                 = false
  backup_bucket_name                    = "agora-management-test-123456789012-backups"
  billing_account_id                    = "ABCDEF-123456-ABCDEF"
  cost_alert_email                      = "infra@example.com"
  operations_alert_email                = "operations@example.com"
  organization_id                       = "123456789012"
  database_operator_principals          = ["group:infra-operators@example.com"]
  authentication_initializer_principals = ["group:authentication-initializers@example.com"]
}

run "invocation_adoption_is_disabled_by_default" {
  command = plan
  assert {
    condition = (
      length(google_tags_location_tag_binding.application) == 0 &&
      length(google_cloud_scheduler_job.json_keys_rotation) == 0 &&
      length(google_project_iam_custom_role.foundation_scheduler) == 0 &&
      length(google_project_iam_member.foundation_scheduler) == 0 &&
      length(google_service_account_iam_member.foundation_scheduler_act_as) == 0
    )
    error_message = "Do not claim existing release objects or grant scheduler access before ownership is released."
  }
}

run "preserves_existing_application_invocation" {
  command = plan
  variables {
    manage_application_invocation = true
    shared_vpc_enabled            = true
    service_release_zones         = { authentication = ["private"], json-keys = ["private"] }
  }
  assert {
    condition = {
      for key, binding in google_tags_location_tag_binding.application : key => [binding.parent, binding.tag_value]
      } == {
      authentication_migrations = ["//run.googleapis.com/projects/agora-production-test/locations/europe-west1/jobs/agora-authentication-migrations", google_tags_tag_value.cloud_run_invocation["release"].id]
      json_keys_migrations      = ["//run.googleapis.com/projects/agora-production-test/locations/europe-west1/jobs/agora-json-keys-migrations", google_tags_tag_value.cloud_run_invocation["release"].id]
      json_keys_rotate          = ["//run.googleapis.com/projects/agora-production-test/locations/europe-west1/jobs/agora-json-keys-rotatekeys", google_tags_tag_value.cloud_run_invocation["scheduled"].id]
      json_keys_smoke           = ["//run.googleapis.com/projects/agora-production-test/locations/europe-west1/jobs/agora-json-keys-smoke", google_tags_tag_value.cloud_run_invocation["release"].id]
      json_keys_grpc            = ["//run.googleapis.com/projects/agora-production-test/locations/europe-west1/services/agora-json-keys-grpc", google_tags_tag_value.cloud_run_invocation["internal"].id]
    }
    error_message = "Preserve all five exact invocation bindings and their authorization classes."
  }
  assert {
    condition = (
      length(google_cloud_scheduler_job.json_keys_rotation) == 1 &&
      google_cloud_scheduler_job.json_keys_rotation[0].name == "agora-json-keys-rotation" &&
      google_cloud_scheduler_job.json_keys_rotation[0].project == var.workload_project_id &&
      google_cloud_scheduler_job.json_keys_rotation[0].region == var.region &&
      google_cloud_scheduler_job.json_keys_rotation[0].schedule == "10 * * * *" &&
      google_cloud_scheduler_job.json_keys_rotation[0].time_zone == "Etc/UTC" &&
      google_cloud_scheduler_job.json_keys_rotation[0].attempt_deadline == "180s" &&
      one(google_cloud_scheduler_job.json_keys_rotation[0].retry_config).retry_count == 1 &&
      one(google_cloud_scheduler_job.json_keys_rotation[0].retry_config).min_backoff_duration == "30s" &&
      one(google_cloud_scheduler_job.json_keys_rotation[0].retry_config).max_backoff_duration == "60s" &&
      one(google_cloud_scheduler_job.json_keys_rotation[0].retry_config).max_doublings == 5 &&
      one(google_cloud_scheduler_job.json_keys_rotation[0].http_target).uri == "https://run.googleapis.com/v2/projects/agora-production-test/locations/europe-west1/jobs/agora-json-keys-rotatekeys:run" &&
      one(google_cloud_scheduler_job.json_keys_rotation[0].http_target).http_method == "POST" &&
      base64decode(one(google_cloud_scheduler_job.json_keys_rotation[0].http_target).body) == "{}" &&
      one(google_cloud_scheduler_job.json_keys_rotation[0].http_target).headers == tomap({ "Content-Type" = "application/json" }) &&
      one(one(google_cloud_scheduler_job.json_keys_rotation[0].http_target).oauth_token).service_account_email == google_service_account.runtime["scheduler_invoker"].email &&
      one(one(google_cloud_scheduler_job.json_keys_rotation[0].http_target).oauth_token).scope == "https://www.googleapis.com/auth/cloud-platform"
    )
    error_message = "Rotation must retain its exact schedule, request, retry bounds and dedicated invoker."
  }
  assert {
    condition = (
      google_project_iam_custom_role.foundation_scheduler[0].project == var.workload_project_id &&
      google_project_iam_custom_role.foundation_scheduler[0].permissions == toset(["cloudscheduler.jobs.get", "cloudscheduler.jobs.fullView", "cloudscheduler.jobs.update"]) &&
      google_project_iam_member.foundation_scheduler[0].project == var.workload_project_id &&
      google_project_iam_member.foundation_scheduler[0].role == google_project_iam_custom_role.foundation_scheduler[0].name &&
      google_project_iam_member.foundation_scheduler[0].member == "serviceAccount:infra-foundation@agora-management-test.iam.gserviceaccount.com" &&
      google_service_account_iam_member.foundation_scheduler_act_as[0].service_account_id == google_service_account.runtime["scheduler_invoker"].name &&
      google_service_account_iam_member.foundation_scheduler_act_as[0].role == "roles/iam.serviceAccountUser" &&
      google_service_account_iam_member.foundation_scheduler_act_as[0].member == google_project_iam_member.foundation_scheduler[0].member
    )
    error_message = "Scheduler authority must exclude create/delete/run and permit attachment of only the dedicated scheduler identity."
  }
}

run "rejects_adoption_without_both_private_boundaries" {
  command = plan
  variables {
    manage_application_invocation = true
  }
  expect_failures = [var.manage_application_invocation]
}

run "rejects_recovery_adoption" {
  command = plan
  variables {
    manage_application_invocation = true
    recovery_mode                 = true
  }
  expect_failures = [var.manage_application_invocation]
}
