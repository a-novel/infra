mock_provider "google" {
  mock_resource "google_cloud_run_v2_service" {
    defaults = {
      uri = "https://agora-json-keys-grpc-test.europe-west1.run.app"
    }
  }
}

variables {
  management_project_id = "agora-management-test"
  workload_project_id   = "agora-production-test"
  backup_bucket_name    = "agora-management-test-123456789012-backups"
  database_private_ip   = "10.20.0.5"
  network_id            = "projects/agora-production-test/global/networks/agora-production"
  subnet_id             = "projects/agora-production-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
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
      length(google_cloud_run_v2_service.authentication[0].traffic) == 2 &&
      one([for traffic in google_cloud_run_v2_service.authentication[0].traffic : traffic if traffic.percent == 0]).tag == "c-0123456789abcdef" &&
      one(google_cloud_run_v2_service.json_keys[0].traffic).percent == 100 &&
      one(google_cloud_run_v2_service.json_keys[0].traffic).revision == var.application_release.json_keys.active_revision &&
      one(google_cloud_run_v2_service.json_keys[0].template).revision == var.application_release.json_keys.revision &&
      !google_cloud_scheduler_job.json_keys_rotation[0].paused
    )
    error_message = "Authentication candidates must preserve JSON Keys traffic, revision and rotation."
  }
}

run "json_keys_candidate_leaves_authentication_active" {
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
      length(google_cloud_run_v2_service.json_keys[0].traffic) == 2 &&
      one([for traffic in google_cloud_run_v2_service.json_keys[0].traffic : traffic if traffic.percent == 0]).tag == "candidate" &&
      one(google_cloud_run_v2_service.authentication[0].traffic).percent == 100 &&
      one(google_cloud_run_v2_service.authentication[0].traffic).revision == var.application_release.authentication.active_revision &&
      one(google_cloud_run_v2_service.authentication[0].template).revision == var.application_release.authentication.revision &&
      google_cloud_scheduler_job.json_keys_rotation[0].paused
    )
    error_message = "JSON Keys candidates must preserve Authentication traffic and revision while pausing only key rotation."
  }
}
