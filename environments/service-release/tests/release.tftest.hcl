mock_provider "google" {}

variables {
  state_bucket          = "agora-management-test-123456789012-tofu-state"
  project_id            = "agora-json-keys-test"
  service               = "json-keys"
  region                = "europe-west1"
  management_project_id = "agora-management-test"
  network = {
    network    = "projects/agora-network-test/global/networks/agora-production"
    subnetwork = "projects/agora-network-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
  }
  images = {
    migrations = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/jobs/migrations@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    rotatekeys = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/jobs/rotatekeys@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
  secret_versions = { postgres-password = 17, app-master-key = 29 }
}

run "documents" {
  # Materialize test data only; this module contains no provider or resources.
  command = apply
  module { source = "./tests/fixtures" }
}

run "json_keys_jobs" {
  command = plan
  variables {
    foundation      = run.documents.cases.json_keys.foundation
    foundation_json = run.documents.cases.json_keys.foundation_json
  }

  assert {
    condition     = output.release_request == null && output.release_operation == null
    error_message = "The API request must remain absent unless explicitly configured."
  }

  assert {
    condition = { for role, job in google_cloud_run_v2_job.application : role => {
      project     = job.project
      region      = job.location
      name        = job.name
      protected   = job.deletion_protection
      tasks       = job.template[0].task_count
      parallelism = job.template[0].parallelism
      account     = job.template[0].template[0].service_account
      environment = job.template[0].template[0].execution_environment
      timeout     = job.template[0].template[0].timeout
      retries     = job.template[0].template[0].max_retries
      image       = job.template[0].template[0].containers[0].image
      limits      = job.template[0].template[0].containers[0].resources[0].limits
      } } == { for role, policy in {
      migrations = { timeout = "600s", retries = 0 }
      rotatekeys = { timeout = "300s", retries = 1 }
      } : role => {
      project     = var.project_id
      region      = var.region
      name        = "agora-json-keys-${role}"
      protected   = true
      tasks       = 1
      parallelism = 1
      account     = "agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com"
      environment = "EXECUTION_ENVIRONMENT_GEN2"
      timeout     = policy.timeout
      retries     = policy.retries
      image       = var.images[role]
      limits      = tomap({ cpu = "1", memory = "512Mi" })
    } }
    error_message = "Create only the two selected-service jobs with single-task executions, bounded resources and no migration retries."
  }

  assert {
    condition = alltrue([for job in values(google_cloud_run_v2_job.application) :
      job.template[0].template[0].vpc_access[0].egress == "ALL_TRAFFIC" &&
      job.template[0].template[0].vpc_access[0].network_interfaces == tolist([{
        network    = var.network.network
        subnetwork = var.network.subnetwork
        tags       = tolist(["agora-json-keys"])
      }]) &&
      { for env in job.template[0].template[0].containers[0].env : env.name => env.value if length(env.value_source) == 0 } == {
        POSTGRES_HOST        = "10.20.0.5"
        POSTGRES_PORT        = "5432"
        POSTGRES_USER        = "agora_json_keys"
        POSTGRES_DATABASE    = "agora_json_keys"
        POSTGRES_TLS_ENABLED = "false"
      }
    ])
    error_message = "Both jobs must use only the selected private database and its foundation-controlled network path."
  }

  assert {
    condition = { for role, job in google_cloud_run_v2_job.application : role => {
      for env in job.template[0].template[0].containers[0].env : env.name => env.value_source[0].secret_key_ref[0]
      if length(env.value_source) > 0
      } } == {
      migrations = {
        POSTGRES_PASSWORD = { secret = "projects/agora-management-test/secrets/production-json-keys-postgres-password", version = "17" }
      }
      rotatekeys = {
        POSTGRES_PASSWORD = { secret = "projects/agora-management-test/secrets/production-json-keys-postgres-password", version = "17" }
        APP_MASTER_KEY    = { secret = "projects/agora-management-test/secrets/production-json-keys-app-master-key", version = "29" }
      }
    }
    error_message = "Only rotation mounts the master key, and the two distinct version pins must not be crossed."
  }
}

run "authentication_jobs" {
  command = plan
  variables {
    project_id      = "agora-authentication-test"
    service         = "authentication"
    foundation      = run.documents.cases.authentication.foundation
    foundation_json = run.documents.cases.authentication.foundation_json
    images = {
      migrations = "europe-west1-docker.pkg.dev/agora-authentication-test/agora-production/service-authentication/jobs/migrations@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
    secret_versions = { postgres-password = 31 }
  }

  assert {
    condition = (
      output.release_request == null &&
      toset(keys(google_cloud_run_v2_job.application)) == toset(["migrations"]) &&
      google_cloud_run_v2_job.application["migrations"].template[0].template[0].service_account == "agora-authentication@agora-authentication-test.iam.gserviceaccount.com" &&
      { for env in google_cloud_run_v2_job.application["migrations"].template[0].template[0].containers[0].env : env.name =>
        length(env.value_source) == 0 ? env.value : "${env.value_source[0].secret_key_ref[0].secret}:${env.value_source[0].secret_key_ref[0].version}"
        } == {
        POSTGRES_HOST        = "10.20.0.6"
        POSTGRES_PORT        = "5433"
        POSTGRES_USER        = "agora_authentication"
        POSTGRES_DATABASE    = "agora_authentication"
        POSTGRES_TLS_ENABLED = "false"
        POSTGRES_PASSWORD    = "projects/agora-management-test/secrets/production-authentication-postgres-password:31"
      }
    )
    error_message = "Authentication must need only its own PostgreSQL contract, with no initializer, SMTP or JSON Keys input."
  }
}

run "reject_initializer" {
  command = plan
  variables {
    foundation      = run.documents.cases.json_keys.foundation
    foundation_json = run.documents.cases.json_keys.foundation_json
    images = {
      migrations = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/jobs/migrations@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      rotatekeys = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/jobs/rotatekeys@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      init       = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/jobs/init@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    }
  }
  expect_failures = [var.images]
}

run "reject_missing_rotation" {
  command = plan
  variables {
    foundation      = run.documents.cases.json_keys.foundation
    foundation_json = run.documents.cases.json_keys.foundation_json
    images = {
      migrations = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/jobs/migrations@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
  expect_failures = [var.images]
}

run "reject_peer_image" {
  command = plan
  variables {
    foundation      = run.documents.cases.json_keys.foundation
    foundation_json = run.documents.cases.json_keys.foundation_json
    images = {
      migrations = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-authentication/jobs/migrations@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      rotatekeys = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/jobs/rotatekeys@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  }
  expect_failures = [var.images]
}

run "reject_mutable_image" {
  command = plan
  variables {
    foundation      = run.documents.cases.json_keys.foundation
    foundation_json = run.documents.cases.json_keys.foundation_json
    images = {
      migrations = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/jobs/migrations:latest"
      rotatekeys = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/jobs/rotatekeys@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  }
  expect_failures = [var.images]
}

run "reject_peer_runtime" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_runtime.foundation
    foundation_json = run.documents.cases.peer_runtime.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_extra_secret" {
  command = plan
  variables {
    foundation      = run.documents.cases.json_keys.foundation
    foundation_json = run.documents.cases.json_keys.foundation_json
    secret_versions = { postgres-password = 17, app-master-key = 29, super-admin-password = 1 }
  }
  expect_failures = [var.secret_versions]
}

run "reject_non_integer_secret_version" {
  command = plan
  variables {
    foundation      = run.documents.cases.json_keys.foundation
    foundation_json = run.documents.cases.json_keys.foundation_json
    secret_versions = { postgres-password = 1.5, app-master-key = 29 }
  }
  expect_failures = [var.secret_versions]
}

run "reject_public_database" {
  command = plan
  variables {
    foundation      = run.documents.cases.public_database.foundation
    foundation_json = run.documents.cases.public_database.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_foreign_state_bucket" {
  command = plan
  variables {
    foundation      = run.documents.cases.json_keys.foundation
    foundation_json = run.documents.cases.json_keys.foundation_json
    state_bucket    = "agora-peer-test-123456789012-tofu-state"
  }
  expect_failures = [var.state_bucket]
}

run "reject_peer_database" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_database.foundation
    foundation_json = run.documents.cases.peer_database.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_missing_database" {
  command = plan
  variables {
    foundation      = run.documents.cases.no_database.foundation
    foundation_json = run.documents.cases.no_database.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_unsupported_document" {
  command = plan
  variables {
    foundation      = run.documents.cases.unsupported.foundation
    foundation_json = run.documents.cases.unsupported.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_malformed_document" {
  command = plan
  variables {
    foundation      = run.documents.cases.malformed.foundation
    foundation_json = run.documents.cases.malformed.foundation_json
  }
  expect_failures = [var.foundation_json]
}

run "reject_altered_bytes" {
  command = plan
  variables {
    foundation      = run.documents.cases.json_keys.foundation
    foundation_json = "${run.documents.cases.json_keys.foundation_json} "
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_reference" {
  command = plan
  variables {
    foundation      = merge(run.documents.cases.json_keys.foundation, { object = run.documents.cases.authentication.foundation.object })
    foundation_json = run.documents.cases.json_keys.foundation_json
  }
  expect_failures = [var.foundation]
}

run "reject_latest_generation" {
  command = plan
  variables {
    foundation      = merge(run.documents.cases.json_keys.foundation, { generation = "latest" })
    foundation_json = run.documents.cases.json_keys.foundation_json
  }
  expect_failures = [var.foundation]
}

run "native_request" {
  command = plan
  variables {
    foundation      = run.documents.cases.rollout.foundation
    foundation_json = run.documents.cases.rollout.foundation_json
    rollout         = run.documents.rollout_input
  }

  assert {
    # The same fixture passes through the actual Go/SDK submission boundary.
    condition     = jsonencode(output.release_request) == jsonencode(yamldecode(file("../../internal/submission/testdata/request.yaml")))
    error_message = "HCL must produce the existing native request contract with the same database, runtime, network and secret pins as the jobs."
  }
}

run "guarded_operation" {
  command = plan
  variables {
    foundation      = run.documents.cases.rollout.foundation
    foundation_json = run.documents.cases.rollout.foundation_json
    rollout         = run.documents.rollout_input
    release_operation = {
      predecessor        = "previous"
      rollout_request_id = "33333333-3333-4333-8333-333333333333"
    }
  }

  assert {
    condition = (
      jsonencode(output.release_operation.request) == jsonencode(output.release_request) &&
      jsonencode(output.release_operation.foundation) == jsonencode(var.foundation) &&
      output.release_operation.foundation_json == var.foundation_json &&
      output.release_operation.predecessor == "previous" &&
      jsonencode(output.release_operation.images) == jsonencode(var.images) &&
      jsonencode(output.release_operation.secret_versions) == jsonencode(var.secret_versions) &&
      alltrue([for role, native in output.release_operation.jobs :
        native.name == "projects/${var.rollout.project_number}/locations/${var.region}/jobs/agora-json-keys-${role}" &&
        native.template.taskCount == 1 && native.template.parallelism == 1 &&
        native.template.template.serviceAccount == google_cloud_run_v2_job.application[role].template[0].template[0].service_account &&
        native.template.template.containers[0].image == var.images[role] &&
        { for env in native.template.template.containers[0].env : env.name => env.value if can(env.value) } ==
        { for env in google_cloud_run_v2_job.application[role].template[0].template[0].containers[0].env : env.name => env.value if length(env.value_source) == 0 } &&
        jsonencode({ for env in native.template.template.containers[0].env : env.name => env.valueSource.secretKeyRef if can(env.valueSource) }) ==
        jsonencode({ for env in google_cloud_run_v2_job.application[role].template[0].template[0].containers[0].env : env.name => env.value_source[0].secret_key_ref[0] if length(env.value_source) > 0 })
      ])
    )
    error_message = "The operation must retain the same approved request, foundation, family, secret references and native job configuration; no second resource owner."
  }
}

run "reject_operation_without_api" {
  command = plan
  variables {
    foundation      = run.documents.cases.json_keys.foundation
    foundation_json = run.documents.cases.json_keys.foundation_json
    release_operation = {
      predecessor        = "previous"
      rollout_request_id = "33333333-3333-4333-8333-333333333333"
    }
  }
  expect_failures = [var.release_operation]
}

run "numeric_foundation_names" {
  command = plan
  variables {
    foundation      = run.documents.cases.numeric_rollout.foundation
    foundation_json = run.documents.cases.numeric_rollout.foundation_json
    rollout         = run.documents.rollout_input
  }

  assert {
    condition     = jsonencode(output.release_request) == jsonencode(yamldecode(file("../../internal/submission/testdata/request.yaml")))
    error_message = "Authorized project-ID and numeric foundation resource names must produce the same numeric SDK request."
  }
}

run "reject_absent_rollout" {
  command = plan
  variables {
    foundation      = run.documents.cases.json_keys.foundation
    foundation_json = run.documents.cases.json_keys.foundation_json
    rollout         = run.documents.rollout_input
  }
  expect_failures = [var.rollout]
}

run "reject_peer_pipeline" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_pipeline.foundation
    foundation_json = run.documents.cases.peer_pipeline.foundation_json
    rollout         = run.documents.rollout_input
  }
  expect_failures = [var.rollout]
}

run "reject_peer_target" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_target.foundation
    foundation_json = run.documents.cases.peer_target.foundation_json
    rollout         = run.documents.rollout_input
  }
  expect_failures = [var.rollout]
}

run "reject_peer_api_image" {
  command = plan
  variables {
    foundation      = run.documents.cases.rollout.foundation
    foundation_json = run.documents.cases.rollout.foundation_json
    rollout         = merge(run.documents.rollout_input, { image = replace(run.documents.rollout_input.image, "agora-json-keys-test", "agora-peer-test") })
  }
  expect_failures = [var.rollout]
}

run "reject_mutable_api_image" {
  command = plan
  variables {
    foundation      = run.documents.cases.rollout.foundation
    foundation_json = run.documents.cases.rollout.foundation_json
    rollout         = merge(run.documents.rollout_input, { image = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/grpc:latest" })
  }
  expect_failures = [var.rollout]
}

run "reject_zero_request_id" {
  command = plan
  variables {
    foundation      = run.documents.cases.rollout.foundation
    foundation_json = run.documents.cases.rollout.foundation_json
    rollout         = merge(run.documents.rollout_input, { request_id = "00000000-0000-0000-0000-000000000000" })
  }
  expect_failures = [var.rollout]
}

run "reject_authentication_api" {
  command = plan
  variables {
    project_id      = "agora-authentication-test"
    service         = "authentication"
    foundation      = run.documents.cases.authentication_rollout.foundation
    foundation_json = run.documents.cases.authentication_rollout.foundation_json
    images = {
      migrations = "europe-west1-docker.pkg.dev/agora-authentication-test/agora-production/service-authentication/jobs/migrations@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
    secret_versions = { postgres-password = 31 }
    rollout         = merge(run.documents.rollout_input, { image = replace(run.documents.rollout_input.image, "agora-json-keys-test", "agora-authentication-test") })
  }
  expect_failures = [var.rollout]
}
