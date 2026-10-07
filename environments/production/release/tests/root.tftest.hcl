mock_provider "google" {}

variables {
  workload_project_id = "agora-production-test"
  cloud_run_invocation_tags = {
    values = {
      internal  = "tagValues/200000000002"
      release   = "tagValues/200000000004"
      scheduled = "tagValues/200000000005"
    }
  }
  runtime_service_accounts = {
    scheduler_invoker = "agora-scheduler-invoker@agora-production-test.iam.gserviceaccount.com"
  }
}

run "preserves_existing_application_invocation" {
  command = plan

  assert {
    condition     = output.root_name == "release" && output.region == "europe-west1"
    error_message = "The retained state and region must not move during backup retirement."
  }

  assert {
    condition = (
      keys(google_tags_location_tag_binding.application) == ["authentication_migrations", "json_keys_migrations", "json_keys_rotate"] &&
      google_tags_location_tag_binding.application["authentication_migrations"].parent == "//run.googleapis.com/projects/agora-production-test/locations/europe-west1/jobs/agora-authentication-migrations" &&
      google_tags_location_tag_binding.application["json_keys_migrations"].parent == "//run.googleapis.com/projects/agora-production-test/locations/europe-west1/jobs/agora-json-keys-migrations" &&
      google_tags_location_tag_binding.application["json_keys_rotate"].parent == "//run.googleapis.com/projects/agora-production-test/locations/europe-west1/jobs/agora-json-keys-rotatekeys" &&
      google_tags_location_tag_binding.application["authentication_migrations"].tag_value == var.cloud_run_invocation_tags.values.release &&
      google_tags_location_tag_binding.application["json_keys_migrations"].tag_value == var.cloud_run_invocation_tags.values.release &&
      google_tags_location_tag_binding.application["json_keys_rotate"].tag_value == var.cloud_run_invocation_tags.values.scheduled
    )
    error_message = "Existing application jobs must retain their exact invocation classes and addresses."
  }

  assert {
    condition = (
      length(google_tags_location_tag_binding.json_keys) == 1 &&
      google_tags_location_tag_binding.json_keys[0].parent == "//run.googleapis.com/projects/agora-production-test/locations/europe-west1/services/agora-json-keys-grpc" &&
      google_tags_location_tag_binding.json_keys[0].tag_value == var.cloud_run_invocation_tags.values.internal &&
      length(google_tags_location_tag_binding.json_keys_smoke) == 1 &&
      google_tags_location_tag_binding.json_keys_smoke[0].parent == "//run.googleapis.com/projects/agora-production-test/locations/europe-west1/jobs/agora-json-keys-smoke" &&
      google_tags_location_tag_binding.json_keys_smoke[0].tag_value == var.cloud_run_invocation_tags.values.release
    )
    error_message = "The internal API and smoke job must retain their scoped invocation tags."
  }

  assert {
    condition = (
      length(google_cloud_scheduler_job.json_keys_rotation) == 1 &&
      google_cloud_scheduler_job.json_keys_rotation[0].name == "agora-json-keys-rotation" &&
      google_cloud_scheduler_job.json_keys_rotation[0].schedule == "10 * * * *" &&
      google_cloud_scheduler_job.json_keys_rotation[0].time_zone == "Etc/UTC" &&
      google_cloud_scheduler_job.json_keys_rotation[0].attempt_deadline == "180s" &&
      one(google_cloud_scheduler_job.json_keys_rotation[0].retry_config).retry_count == 1 &&
      one(google_cloud_scheduler_job.json_keys_rotation[0].http_target).uri == "https://run.googleapis.com/v2/projects/agora-production-test/locations/europe-west1/jobs/agora-json-keys-rotatekeys:run" &&
      one(google_cloud_scheduler_job.json_keys_rotation[0].http_target).http_method == "POST" &&
      base64decode(one(google_cloud_scheduler_job.json_keys_rotation[0].http_target).body) == "{}" &&
      one(one(google_cloud_scheduler_job.json_keys_rotation[0].http_target).oauth_token).service_account_email == var.runtime_service_accounts.scheduler_invoker
    )
    error_message = "Key rotation must preserve its existing schedule, exact job and dedicated invoker."
  }
}

run "rejects_other_scheduler_identity" {
  command = plan

  variables {
    runtime_service_accounts = {
      scheduler_invoker = "operator@agora-production-test.iam.gserviceaccount.com"
    }
  }

  expect_failures = [var.runtime_service_accounts]
}

run "rejects_noncanonical_invocation_tags" {
  command = plan

  variables {
    cloud_run_invocation_tags = {
      values = { internal = "internal", release = "tagValues/4", scheduled = "tagValues/5" }
    }
  }

  expect_failures = [var.cloud_run_invocation_tags]
}
