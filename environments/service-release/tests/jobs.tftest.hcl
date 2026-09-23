mock_provider "google" {}

variables {
  state_bucket = "agora-management-test-123456789012-tofu-state"
  runtime = {
    schema_version  = 1
    project_id      = "agora-json-keys-test"
    service         = "json-keys"
    region          = "europe-west1"
    service_account = "agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com"
  }
  management_project_id = "agora-management-test"
  database_private_ip   = "10.20.0.5"
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

run "json_keys_jobs" {
  command = plan

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
      project     = var.runtime.project_id
      region      = var.runtime.region
      name        = "agora-json-keys-${role}"
      protected   = true
      tasks       = 1
      parallelism = 1
      account     = var.runtime.service_account
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
        POSTGRES_HOST        = var.database_private_ip
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
    runtime = {
      schema_version  = 1
      project_id      = "agora-authentication-test"
      service         = "authentication"
      region          = "europe-west1"
      service_account = "agora-authentication@agora-authentication-test.iam.gserviceaccount.com"
    }
    images = {
      migrations = "europe-west1-docker.pkg.dev/agora-authentication-test/agora-production/service-authentication/jobs/migrations@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
    secret_versions = { postgres-password = 31 }
  }

  assert {
    condition = (
      toset(keys(google_cloud_run_v2_job.application)) == toset(["migrations"]) &&
      google_cloud_run_v2_job.application["migrations"].template[0].template[0].service_account == var.runtime.service_account &&
      { for env in google_cloud_run_v2_job.application["migrations"].template[0].template[0].containers[0].env : env.name =>
        length(env.value_source) == 0 ? env.value : "${env.value_source[0].secret_key_ref[0].secret}:${env.value_source[0].secret_key_ref[0].version}"
        } == {
        POSTGRES_HOST        = var.database_private_ip
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
    images = {
      migrations = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/jobs/migrations@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
  expect_failures = [var.images]
}

run "reject_peer_image" {
  command = plan
  variables {
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
    runtime = {
      schema_version  = 1
      project_id      = "agora-json-keys-test"
      service         = "json-keys"
      region          = "europe-west1"
      service_account = "agora-authentication@agora-authentication-test.iam.gserviceaccount.com"
    }
  }
  expect_failures = [var.runtime]
}

run "reject_extra_secret" {
  command = plan
  variables { secret_versions = { postgres-password = 17, app-master-key = 29, super-admin-password = 1 } }
  expect_failures = [var.secret_versions]
}

run "reject_non_integer_secret_version" {
  command = plan
  variables { secret_versions = { postgres-password = 1.5, app-master-key = 29 } }
  expect_failures = [var.secret_versions]
}

run "reject_public_database" {
  command = plan
  variables { database_private_ip = "8.8.8.8" }
  expect_failures = [var.database_private_ip]
}

run "reject_foreign_state_bucket" {
  command = plan
  variables { state_bucket = "agora-peer-test-123456789012-tofu-state" }
  expect_failures = [var.state_bucket]
}
