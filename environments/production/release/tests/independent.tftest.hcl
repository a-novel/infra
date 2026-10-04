mock_provider "google" {
  mock_data "google_cloud_run_v2_service" {
    defaults = {
      uri = "https://agora-json-keys-grpc-test.europe-west1.run.app"
    }
  }
}

variables {
  management_project_id = "agora-management-test"
  workload_project_id   = "agora-production-test"
  backup_bucket_name    = "agora-management-test-123456789012-backups"
  database_hosts = {
    authentication = { private_ip = "10.20.0.5", data_disk_id = "1001" }
    json_keys      = { private_ip = "10.20.0.6", data_disk_id = "1002" }
  }
  network_id = "projects/agora-production-test/global/networks/agora-production"
  subnet_id  = "projects/agora-production-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
  cloud_run_invocation_tags = {
    key = "tagKeys/100000000001"
    values = {
      initializer = "tagValues/200000000001"
      internal    = "tagValues/200000000002"
      recovery    = "tagValues/200000000003"
      release     = "tagValues/200000000004"
      scheduled   = "tagValues/200000000005"
    }
  }
  runtime_service_accounts = {
    authentication    = "agora-authentication@agora-production-test.iam.gserviceaccount.com"
    backup            = "agora-backup@agora-production-test.iam.gserviceaccount.com"
    json_keys         = "agora-json-keys@agora-production-test.iam.gserviceaccount.com"
    restore           = "agora-restore@agora-production-test.iam.gserviceaccount.com"
    scheduler_invoker = "agora-scheduler-invoker@agora-production-test.iam.gserviceaccount.com"
  }
  database_releases = {
    authentication = {
      image                   = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/database@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      backup_password_version = 11
    }
    json_keys = {
      image                   = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/database@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      backup_password_version = 7
    }
  }
}

run "active_baseline" {
  command = apply
  variables {
    application_release = jsondecode(file("../../../tests/fixtures/application-release.json"))
  }
  assert {
    condition     = length(google_cloud_run_v2_service.authentication) == 0
    error_message = "Historical receipts must not recreate the retired private-project API."
  }
}

run "retained_waitlist_settings_cannot_leak_into_private_runtimes" {
  command = plan
  variables {
    application_release = merge(jsondecode(file("../../../tests/fixtures/application-release.json")), {
      authentication = merge(jsondecode(file("../../../tests/fixtures/application-release.json")).authentication, {
        waitlist = { url = "https://script.google.com/macros/s/fixture-id/exec", secret_version = 14 }
      })
    })
  }
  assert {
    condition = (
      length(google_cloud_run_v2_service.authentication) == 0 &&
      length(google_cloud_run_v2_service.recovery_json_keys) == 0
    )
    error_message = "Private JSON Keys must not mount the public API's waitlist settings."
  }
}

run "rejects_waitlist_development_url" {
  command = plan
  variables {
    application_release = merge(jsondecode(file("../../../tests/fixtures/application-release.json")), {
      authentication = merge(jsondecode(file("../../../tests/fixtures/application-release.json")).authentication, {
        waitlist = { url = "https://script.google.com/macros/s/fixture-id/dev", secret_version = 14 }
      })
    })
  }
  expect_failures = [var.application_release]
}

run "rejects_waitlist_fractional_version" {
  command = plan
  variables {
    application_release = merge(jsondecode(file("../../../tests/fixtures/application-release.json")), {
      authentication = merge(jsondecode(file("../../../tests/fixtures/application-release.json")).authentication, {
        waitlist = { url = "https://script.google.com/macros/s/fixture-id/exec", secret_version = 1.5 }
      })
    })
  }
  expect_failures = [var.application_release]
}

run "authentication_candidate_leaves_json_keys_active" {
  command = plan
  variables {
    application_release = merge(jsondecode(file("../../../tests/fixtures/application-release.json")), {
      rollout = { candidate_tag = "c-0123456789abcdef", phase = "candidate", services = ["authentication"] }
    })
  }
  assert {
    condition = (
      length(google_cloud_run_v2_service.authentication) == 0 &&
      length(google_cloud_run_v2_service.recovery_json_keys) == 0 &&
      !google_cloud_scheduler_job.json_keys_rotation[0].paused
    )
    error_message = "Authentication candidates must preserve JSON Keys traffic, revision and rotation."
  }
}

run "json_keys_candidate_does_not_recreate_authentication" {
  command = plan
  variables {
    application_release = merge(jsondecode(file("../../../tests/fixtures/application-release.json")), {
      rollout = { candidate_tag = "c-0123456789abcdef", phase = "candidate", services = ["json_keys"] }
    })
  }
  assert {
    condition = (
      length(google_cloud_run_v2_job.json_keys_smoke) == 1 &&
      one(one(google_cloud_run_v2_job.json_keys_smoke[0].template).template).service_account == var.runtime_service_accounts.json_keys &&
      one(one(google_cloud_run_v2_job.json_keys_smoke[0].template).template).max_retries == 0 &&
      one(one(google_cloud_run_v2_job.json_keys_smoke[0].template).template).timeout == "90s" &&
      one(one(google_cloud_run_v2_job.json_keys_smoke[0].template).template).vpc_access[0].egress == "ALL_TRAFFIC" &&
      one(one(one(google_cloud_run_v2_job.json_keys_smoke[0].template).template).containers).image == var.application_release.json_keys.images.grpc &&
      one(one(one(one(google_cloud_run_v2_job.json_keys_smoke[0].template).template).containers).command) == "/bin/sh" &&
      alltrue([for env in one(one(one(google_cloud_run_v2_job.json_keys_smoke[0].template).template).containers).env : length(env.value_source) == 0]) &&
      google_tags_location_tag_binding.json_keys_smoke[0].tag_value == var.cloud_run_invocation_tags.values.release
    )
    error_message = "The private smoke job must reuse the selected image and existing caller without secrets, retries or scheduler authority."
  }
  assert {
    condition = (
      length(google_cloud_run_v2_service.recovery_json_keys) == 0 &&
      length(google_cloud_run_v2_service.authentication) == 0 &&
      google_cloud_scheduler_job.json_keys_rotation[0].paused
    )
    error_message = "JSON Keys candidates must not own Authentication and must pause only key rotation."
  }
}
