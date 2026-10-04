mock_provider "google" {}

variables {
  state_bucket          = "agora-management-test-123456789012-tofu-state"
  project_id            = "agora-public-api-test"
  private_project_id    = "agora-private-test"
  service               = "json-keys"
  zone                  = "public-api"
  region                = "europe-west1"
  management_project_id = "agora-management-test"
  network = {
    network    = "projects/agora-private-test/global/networks/agora-production"
    subnetwork = "projects/agora-private-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
  }
  images          = {}
  secret_versions = { postgres-password = 17 }
}

run "documents" {
  command = apply
  module { source = "./tests/fixtures/shared" }
  variables { zone = "public-api" }
}

run "json_keys_request" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    rollout         = run.documents.rollout.json-keys
  }
  assert {
    condition = (
      jsonencode(output.release_request) == jsonencode(yamldecode(file("../../internal/submission/testdata/sharedRequests.yaml"))["public-api/json-keys"]) &&
      length(google_cloud_run_v2_job.application) == 0 && output.release_operation == null
    )
    error_message = "REST must use its own identity and source, the existing private database and only its database secret, with no jobs or executable operation."
  }
}

run "authentication_request" {
  command = plan
  variables {
    service         = "authentication"
    foundation      = run.documents.cases.authentication.foundation
    foundation_json = run.documents.cases.authentication.foundation_json
    rollout         = run.documents.rollout.authentication
    authentication  = run.documents.authentication
    secret_versions = { postgres-password = 17, smtp-sender-password = 21 }
  }
  assert {
    condition = (
      jsonencode(output.release_request) == jsonencode(yamldecode(file("../../internal/submission/testdata/sharedRequests.yaml"))["public-api/authentication"]) &&
      length(google_cloud_run_v2_job.application) == 0 && output.release_operation == null
    )
    error_message = "Authentication must retain its separate private database and SMTP configuration without adding a job owner or waitlist access."
  }
}

run "authentication_waitlist" {
  command = plan
  variables {
    service         = "authentication"
    foundation      = run.documents.cases.authentication.foundation
    foundation_json = run.documents.cases.authentication.foundation_json
    rollout         = run.documents.rollout.authentication
    authentication  = merge(run.documents.authentication, { waitlist_url = "https://waitlist.example.test" })
    secret_versions = { postgres-password = 17, smtp-sender-password = 21, waitlist-secret = 31 }
  }
  assert {
    condition = jsonencode(output.release_request) == jsonencode(merge(yamldecode(file("../../internal/submission/testdata/sharedRequests.yaml"))["public-api/authentication"], {
      release = merge(yamldecode(file("../../internal/submission/testdata/sharedRequests.yaml"))["public-api/authentication"].release, {
        skaffoldConfigPath = "skaffold-waitlist.yaml"
        deployParameters = merge(yamldecode(file("../../internal/submission/testdata/sharedRequests.yaml"))["public-api/authentication"].release.deployParameters, {
          waitlistURL = "https://waitlist.example.test", waitlistSecretVersion = "31",
        })
      })
    })) && length(google_cloud_run_v2_job.application) == 0
    error_message = "Explicit waitlist configuration must pair its HTTPS endpoint, exact secret version and reviewed manifest."
  }
}

run "reject_job_images" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    rollout         = run.documents.rollout.json-keys
    images          = { migrations = "europe-west1-docker.pkg.dev/agora-public-api-test/agora-json-keys-api-production/service-json-keys/jobs/migrations@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  }
  expect_failures = [var.images]
}

run "reject_master_key" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    rollout         = run.documents.rollout.json-keys
    secret_versions = { postgres-password = 17, app-master-key = 29 }
  }
  expect_failures = [var.secret_versions]
}

run "reject_unpinned_secret" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    rollout         = run.documents.rollout.json-keys
    secret_versions = { postgres-password = 0 }
  }
  expect_failures = [var.secret_versions]
}

run "reject_peer_scope" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_scope.foundation
    foundation_json = run.documents.cases.peer_scope.foundation_json
    rollout         = run.documents.rollout.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_runtime" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_runtime.foundation
    foundation_json = run.documents.cases.peer_runtime.foundation_json
    rollout         = run.documents.rollout.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_database" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_database.foundation
    foundation_json = run.documents.cases.peer_database.foundation_json
    rollout         = run.documents.rollout.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_public_database" {
  command = plan
  variables {
    foundation      = run.documents.cases.public_database.foundation
    foundation_json = run.documents.cases.public_database.foundation_json
    rollout         = run.documents.rollout.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_project" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_project.foundation
    foundation_json = run.documents.cases.peer_project.foundation_json
    rollout         = run.documents.rollout.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_missing_source" {
  command = plan
  variables {
    foundation      = run.documents.cases.missing_source.foundation
    foundation_json = run.documents.cases.missing_source.foundation_json
    rollout         = run.documents.rollout.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_source" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_source.foundation
    foundation_json = run.documents.cases.peer_source.foundation_json
    rollout         = run.documents.rollout.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_registry" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_registry.foundation
    foundation_json = run.documents.cases.peer_registry.foundation_json
    rollout         = run.documents.rollout.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_latest_source" {
  command = plan
  variables {
    foundation      = run.documents.cases.latest_source.foundation
    foundation_json = run.documents.cases.latest_source.foundation_json
    rollout         = run.documents.rollout.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_pipeline" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_pipeline.foundation
    foundation_json = run.documents.cases.peer_pipeline.foundation_json
    rollout         = run.documents.rollout.json-keys
  }
  expect_failures = [var.rollout]
}

run "reject_peer_target" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_target.foundation
    foundation_json = run.documents.cases.peer_target.foundation_json
    rollout         = run.documents.rollout.json-keys
  }
  expect_failures = [var.rollout]
}

run "reject_no_rollout" {
  command = plan
  variables {
    foundation      = run.documents.cases.no_rollout.foundation
    foundation_json = run.documents.cases.no_rollout.foundation_json
    rollout         = run.documents.rollout.json-keys
  }
  expect_failures = [var.rollout]
}

run "reject_missing_private_project" {
  command = plan
  variables {
    foundation         = run.documents.cases.json-keys.foundation
    foundation_json    = run.documents.cases.json-keys.foundation_json
    rollout            = run.documents.rollout.json-keys
    private_project_id = null
  }
  expect_failures = [var.private_project_id]
}

run "reject_private_project_equals_api" {
  command = plan
  variables {
    foundation         = run.documents.cases.json-keys.foundation
    foundation_json    = run.documents.cases.json-keys.foundation_json
    rollout            = run.documents.rollout.json-keys
    private_project_id = "agora-public-api-test"
  }
  expect_failures = [var.private_project_id]
}

run "reject_peer_network" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    rollout         = run.documents.rollout.json-keys
    network         = { network = "projects/agora-peer-test/global/networks/agora-production", subnetwork = "projects/agora-peer-test/regions/europe-west1/subnetworks/agora-production-europe-west1" }
  }
  expect_failures = [var.network]
}

run "reject_private_image" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    rollout         = merge(run.documents.rollout.json-keys, { image = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-production/service-json-keys/grpc@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" })
  }
  expect_failures = [var.rollout]
}

run "reject_shared_operation" {
  command = plan
  variables {
    foundation        = run.documents.cases.json-keys.foundation
    foundation_json   = run.documents.cases.json-keys.foundation_json
    rollout           = run.documents.rollout.json-keys
    release_operation = { predecessor = "previous", rollout_request_id = "33333333-3333-4333-8333-333333333333" }
  }
  expect_failures = [var.release_operation]
}

run "reject_missing_authentication" {
  command = plan
  variables {
    service         = "authentication"
    foundation      = run.documents.cases.authentication.foundation
    foundation_json = run.documents.cases.authentication.foundation_json
    rollout         = run.documents.rollout.authentication
    authentication  = null
    secret_versions = { postgres-password = 17, smtp-sender-password = 21 }
  }
  expect_failures = [var.authentication]
}

run "reject_invalid_json_keys_endpoint" {
  command = plan
  variables {
    service         = "authentication"
    foundation      = run.documents.cases.authentication.foundation
    foundation_json = run.documents.cases.authentication.foundation_json
    rollout         = run.documents.rollout.authentication
    authentication  = merge(run.documents.authentication, { json_keys_host = "unexpected.example.test" })
    secret_versions = { postgres-password = 17, smtp-sender-password = 21 }
  }
  expect_failures = [var.authentication]
}

run "reject_waitlist_missing_secret" {
  command = plan
  variables {
    service         = "authentication"
    foundation      = run.documents.cases.authentication.foundation
    foundation_json = run.documents.cases.authentication.foundation_json
    rollout         = run.documents.rollout.authentication
    authentication  = merge(run.documents.authentication, { waitlist_url = "https://waitlist.example.test" })
    secret_versions = { postgres-password = 17, smtp-sender-password = 21 }
  }
  expect_failures = [var.secret_versions]
}

run "reject_waitlist_without_endpoint" {
  command = plan
  variables {
    service         = "authentication"
    foundation      = run.documents.cases.authentication.foundation
    foundation_json = run.documents.cases.authentication.foundation_json
    rollout         = run.documents.rollout.authentication
    authentication  = run.documents.authentication
    secret_versions = { postgres-password = 17, smtp-sender-password = 21, waitlist-secret = 31 }
  }
  expect_failures = [var.secret_versions]
}

run "reject_insecure_waitlist" {
  command = plan
  variables {
    service         = "authentication"
    foundation      = run.documents.cases.authentication.foundation
    foundation_json = run.documents.cases.authentication.foundation_json
    rollout         = run.documents.rollout.authentication
    authentication  = merge(run.documents.authentication, { waitlist_url = "http://waitlist.example.test" })
    secret_versions = { postgres-password = 17, smtp-sender-password = 21, waitlist-secret = 31 }
  }
  expect_failures = [var.authentication]
}

run "reject_invalid_smtp" {
  command = plan
  variables {
    service         = "authentication"
    foundation      = run.documents.cases.authentication.foundation
    foundation_json = run.documents.cases.authentication.foundation_json
    rollout         = run.documents.rollout.authentication
    authentication  = merge(run.documents.authentication, { smtp_username = "unsafe\nvalue" })
    secret_versions = { postgres-password = 17, smtp-sender-password = 21 }
  }
  expect_failures = [var.authentication]
}
