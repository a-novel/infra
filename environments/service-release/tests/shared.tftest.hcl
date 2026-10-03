mock_provider "google" {}

variables {
  state_bucket          = "agora-management-test-123456789012-tofu-state"
  project_id            = "agora-private-test"
  service               = "json-keys"
  zone                  = "private"
  region                = "europe-west1"
  management_project_id = "agora-management-test"
  network = {
    network    = "projects/agora-private-test/global/networks/agora-production"
    subnetwork = "projects/agora-private-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
  }
  images = {
    migrations = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-production/service-json-keys/jobs/migrations@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    rotatekeys = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-production/service-json-keys/jobs/rotatekeys@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
  secret_versions = { postgres-password = 17, app-master-key = 29 }
}

run "documents" {
  command = apply
  module { source = "./tests/fixtures/shared" }
}

run "json_keys_private_jobs" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
  }
  assert {
    condition = (
      toset(keys(google_cloud_run_v2_job.application)) == toset(["migrations", "rotatekeys"]) &&
      alltrue([for role, job in google_cloud_run_v2_job.application :
        job.project == var.project_id &&
        job.template[0].template[0].service_account == "agora-json-keys-private@agora-private-test.iam.gserviceaccount.com" &&
        job.template[0].template[0].containers[0].image == var.images[role] &&
        { for env in job.template[0].template[0].containers[0].env : env.name => env.value if length(env.value_source) == 0 } == {
          POSTGRES_HOST     = "10.20.0.5", POSTGRES_PORT = "5432", POSTGRES_USER = "agora_json_keys",
          POSTGRES_DATABASE = "agora_json_keys", POSTGRES_TLS_ENABLED = "false",
        }
      ]) && output.release_request == null && output.release_operation == null
    )
    error_message = "Private jobs must retain their service identity, images and existing private endpoint without enrolling API rollout."
  }
}

run "authentication_private_jobs" {
  command = plan
  variables {
    service         = "authentication"
    foundation      = run.documents.cases.authentication.foundation
    foundation_json = run.documents.cases.authentication.foundation_json
    images          = { migrations = "europe-west1-docker.pkg.dev/agora-private-test/agora-authentication-private-production/service-authentication/jobs/migrations@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
    secret_versions = { postgres-password = 31 }
  }
  assert {
    condition = (
      toset(keys(google_cloud_run_v2_job.application)) == toset(["migrations"]) &&
      google_cloud_run_v2_job.application["migrations"].template[0].template[0].service_account == "agora-authentication-private@agora-private-test.iam.gserviceaccount.com" &&
      { for env in google_cloud_run_v2_job.application["migrations"].template[0].template[0].containers[0].env :
        env.name => env.value if contains(["POSTGRES_HOST", "POSTGRES_PORT"], env.name)
      } == { POSTGRES_HOST = "10.20.0.6", POSTGRES_PORT = "5433" }
    )
    error_message = "Authentication must keep its own private endpoint and never create rotation jobs."
  }
}

run "reject_peer_scope" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_scope.foundation
    foundation_json = run.documents.cases.peer_scope.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_runtime" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_runtime.foundation
    foundation_json = run.documents.cases.peer_runtime.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_no_database" {
  command = plan
  variables {
    foundation      = run.documents.cases.no_database.foundation
    foundation_json = run.documents.cases.no_database.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_database" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_database.foundation
    foundation_json = run.documents.cases.peer_database.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_public_database" {
  command = plan
  variables {
    foundation      = run.documents.cases.public_database.foundation
    foundation_json = run.documents.cases.public_database.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_missing_source" {
  command = plan
  variables {
    foundation      = run.documents.cases.missing_source.foundation
    foundation_json = run.documents.cases.missing_source.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_source" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_source.foundation
    foundation_json = run.documents.cases.peer_source.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_latest_source" {
  command = plan
  variables {
    foundation      = run.documents.cases.latest_source.foundation
    foundation_json = run.documents.cases.latest_source.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_legacy_schema" {
  command = plan
  variables {
    foundation      = run.documents.cases.legacy_schema.foundation
    foundation_json = run.documents.cases.legacy_schema.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_api_runtime" {
  command = plan
  variables {
    foundation      = run.documents.cases.api_runtime.foundation
    foundation_json = run.documents.cases.api_runtime.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_registry" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_registry.foundation
    foundation_json = run.documents.cases.peer_registry.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_public_api_jobs" {
  command = plan
  variables {
    zone            = "public-api"
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
  }
  expect_failures = [var.zone]
}

run "reject_public_jobs" {
  command = plan
  variables {
    zone            = "public"
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
  }
  expect_failures = [var.zone]
}

run "reject_downgraded_reference" {
  command = plan
  variables {
    foundation      = merge(run.documents.cases.json-keys.foundation, { schema_version = 1 })
    foundation_json = run.documents.cases.json-keys.foundation_json
  }
  expect_failures = [var.foundation]
}

run "reject_dedicated_folder" {
  command = plan
  variables {
    foundation      = merge(run.documents.cases.json-keys.foundation, { object = "foundation/coordinates/agora-private-test/${run.documents.cases.json-keys.foundation.sha256}.json" })
    foundation_json = run.documents.cases.json-keys.foundation_json
  }
  expect_failures = [var.foundation]
}

run "reject_shared_rollout" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    rollout = {
      project_number   = "123456"
      image            = "europe-west1-docker.pkg.dev/agora-private-test/agora-production/service-json-keys/grpc@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      release_id       = "release-1"
      request_id       = "11111111-2222-4333-8444-555555555555"
      source_commit    = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      skaffold_version = "2.17.1"
    }
  }
  expect_failures = [var.rollout]
}

run "reject_legacy_image_path" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    images = {
      migrations = "europe-west1-docker.pkg.dev/agora-private-test/agora-production/service-json-keys/jobs/migrations@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      rotatekeys = "europe-west1-docker.pkg.dev/agora-private-test/agora-production/service-json-keys/jobs/rotatekeys@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  }
  expect_failures = [var.images]
}

run "reject_lookalike_registry" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    images = {
      migrations = "europe-west1-dockerXpkgYdev/agora-private-test/agora-json-keys-private-production/service-json-keys/jobs/migrations@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      rotatekeys = "europe-west1-dockerXpkgYdev/agora-private-test/agora-json-keys-private-production/service-json-keys/jobs/rotatekeys@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  }
  expect_failures = [var.images]
}
