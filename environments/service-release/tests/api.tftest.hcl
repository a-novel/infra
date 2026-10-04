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

run "json_keys_api" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    api             = run.documents.api.json-keys
  }
  assert {
    condition = (
      length(google_cloud_run_v2_job.application) == 0 &&
      google_cloud_run_v2_service.api[0].project == var.project_id &&
      google_cloud_run_v2_service.api[0].ingress == "INGRESS_TRAFFIC_ALL" &&
      google_cloud_run_v2_service.api[0].invoker_iam_disabled == true &&
      google_cloud_run_v2_service.api[0].template[0].service_account == "agora-json-keys-api@agora-public-api-test.iam.gserviceaccount.com" &&
      google_cloud_run_v2_service.api[0].scaling[0].min_instance_count == 0 &&
      google_cloud_run_v2_service.api[0].scaling[0].max_instance_count == 3 &&
      google_cloud_run_v2_service.api[0].template[0].containers[0].image == var.api.image &&
      google_cloud_run_v2_service.api[0].template[0].containers[0].resources[0].limits == tomap({ cpu = "1", memory = "512Mi" }) &&
      { for env in google_cloud_run_v2_service.api[0].template[0].containers[0].env : env.name => env.value_source[0].secret_key_ref[0]
        if length(env.value_source) > 0
      } == { POSTGRES_PASSWORD = { secret = "projects/agora-management-test/secrets/production-json-keys-postgres-password", version = "17" } }
    )
    error_message = "REST must use its own identity, bounded scale-to-zero capacity and only the database credential; no master key or jobs."
  }
  assert {
    condition = (
      google_cloud_run_v2_service.api[0].template[0].vpc_access[0].egress == "PRIVATE_RANGES_ONLY" &&
      google_cloud_run_v2_service.api[0].template[0].vpc_access[0].network_interfaces[0].network == var.network.network &&
      { for env in google_cloud_run_v2_service.api[0].template[0].containers[0].env : env.name => env.value
        if contains(["POSTGRES_HOST", "POSTGRES_PORT"], env.name)
      } == { POSTGRES_HOST = "10.20.0.5", POSTGRES_PORT = "5432" } &&
      { for traffic in google_cloud_run_v2_service.api[0].traffic : traffic.revision => traffic.percent } == {
        agora-json-keys-rest-active = 100, agora-json-keys-rest-candidate = 0
      } &&
      one([for traffic in google_cloud_run_v2_service.api[0].traffic : traffic.tag if traffic.percent == 0]) == "candidate"
    )
    error_message = "The candidate must retain the shared private database and leave all normal traffic on the healthy revision."
  }
}

run "authentication_api" {
  command = plan
  variables {
    service         = "authentication"
    foundation      = run.documents.cases.authentication.foundation
    foundation_json = run.documents.cases.authentication.foundation_json
    api             = run.documents.api.authentication
    authentication  = run.documents.authentication
    secret_versions = { postgres-password = 17, smtp-sender-password = 21 }
  }
  assert {
    condition = (
      length(google_cloud_run_v2_job.application) == 0 &&
      google_cloud_run_v2_service.api[0].template[0].containers[0].resources[0].cpu_idle == false &&
      google_cloud_run_v2_service.api[0].scaling[0].min_instance_count == 1 &&
      { for env in google_cloud_run_v2_service.api[0].template[0].containers[0].env : env.name => env.value
        if contains(["POSTGRES_HOST", "POSTGRES_PORT", "SERVICE_JSON_KEYS_HOST", "REST_TIMEOUT_SHUTDOWN"], env.name)
        } == {
        POSTGRES_HOST          = "10.20.0.6", POSTGRES_PORT = "5433",
        SERVICE_JSON_KEYS_HOST = var.authentication.json_keys_host, REST_TIMEOUT_SHUTDOWN = "9s",
      } &&
      toset([for env in google_cloud_run_v2_service.api[0].template[0].containers[0].env : env.name
        if length(env.value_source) > 0
      ]) == toset(["POSTGRES_PASSWORD", "SMTP_SENDER_PASSWORD"])
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
    api             = run.documents.api.authentication
    authentication  = merge(run.documents.authentication, { waitlist_url = "https://waitlist.example.test" })
    secret_versions = { postgres-password = 17, smtp-sender-password = 21, waitlist-secret = 31 }
  }
  assert {
    condition = (
      one([for env in google_cloud_run_v2_service.api[0].template[0].containers[0].env : env.value if env.name == "WAITLIST_URL"]) == "https://waitlist.example.test" &&
      one([for env in google_cloud_run_v2_service.api[0].template[0].containers[0].env : env.value_source[0].secret_key_ref[0] if env.name == "WAITLIST_SECRET"]) == {
        secret = "projects/agora-management-test/secrets/production-authentication-waitlist-secret", version = "31"
      }
    )
    error_message = "Waitlist access must pair the approved endpoint and exact secret version."
  }
}

run "promote_verified_candidate" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    api             = merge(run.documents.api.json-keys, { serving_revision = run.documents.api.json-keys.revision })
  }
  assert {
    condition = (
      length(google_cloud_run_v2_service.api[0].traffic) == 1 &&
      google_cloud_run_v2_service.api[0].traffic[0].revision == var.api.revision &&
      google_cloud_run_v2_service.api[0].traffic[0].percent == 100 &&
      google_cloud_run_v2_service.api[0].traffic[0].type == "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION"
    )
    error_message = "Promotion must route to one explicit revision, never a moving latest selector."
  }
}

run "candidate_endpoint_before_traffic_status" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    api             = run.documents.api.json-keys
  }
  override_resource {
    target = google_cloud_run_v2_service.api[0]
    values = {
      uri              = "https://agora-json-keys-rest-example-ew.a.run.app"
      traffic_statuses = []
    }
  }
  assert {
    condition     = output.api.candidate_uri == "https://candidate---agora-json-keys-rest-example-ew.a.run.app"
    error_message = "The declared candidate endpoint must remain stable while Cloud Run traffic status catches up."
  }
}

run "promoted_endpoint_ignores_stale_traffic_status" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    api             = merge(run.documents.api.json-keys, { serving_revision = run.documents.api.json-keys.revision })
  }
  override_resource {
    target = google_cloud_run_v2_service.api[0]
    values = {
      uri = "https://agora-json-keys-rest-example-ew.a.run.app"
      traffic_statuses = [{
        tag      = "candidate"
        uri      = "https://candidate---agora-json-keys-rest-example-ew.a.run.app"
        revision = "agora-json-keys-rest-candidate"
        percent  = 0
        type     = "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION"
      }]
    }
  }
  assert {
    condition     = output.api.candidate_uri == null
    error_message = "A promoted service must stop advertising a candidate even while observed traffic retains its old tag."
  }
}

run "reject_peer_revision" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    api             = merge(run.documents.api.json-keys, { serving_revision = "agora-authentication-rest-active" })
  }
  expect_failures = [var.api]
}

run "reject_latest_revision" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    api             = merge(run.documents.api.json-keys, { serving_revision = "latest" })
  }
  expect_failures = [var.api]
}

run "reject_mutable_image" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    api             = merge(run.documents.api.json-keys, { image = "europe-west1-docker.pkg.dev/agora-public-api-test/agora-json-keys-api-production/service-json-keys/rest:latest" })
  }
  expect_failures = [var.api]
}

run "reject_job_images" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    api             = run.documents.api.json-keys
    images          = { migrations = "europe-west1-docker.pkg.dev/agora-public-api-test/agora-json-keys-api-production/service-json-keys/jobs/migrations@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  }
  expect_failures = [var.images]
}

run "reject_master_key" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    api             = run.documents.api.json-keys
    secret_versions = { postgres-password = 17, app-master-key = 29 }
  }
  expect_failures = [var.secret_versions]
}

run "reject_unpinned_secret" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    api             = run.documents.api.json-keys
    secret_versions = { postgres-password = 0 }
  }
  expect_failures = [var.secret_versions]
}

run "reject_peer_scope" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_scope.foundation
    foundation_json = run.documents.cases.peer_scope.foundation_json
    api             = run.documents.api.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_runtime" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_runtime.foundation
    foundation_json = run.documents.cases.peer_runtime.foundation_json
    api             = run.documents.api.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_database" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_database.foundation
    foundation_json = run.documents.cases.peer_database.foundation_json
    api             = run.documents.api.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_public_database" {
  command = plan
  variables {
    foundation      = run.documents.cases.public_database.foundation
    foundation_json = run.documents.cases.public_database.foundation_json
    api             = run.documents.api.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_project" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_project.foundation
    foundation_json = run.documents.cases.peer_project.foundation_json
    api             = run.documents.api.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_missing_source" {
  command = plan
  variables {
    foundation      = run.documents.cases.missing_source.foundation
    foundation_json = run.documents.cases.missing_source.foundation_json
    api             = run.documents.api.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_source" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_source.foundation
    foundation_json = run.documents.cases.peer_source.foundation_json
    api             = run.documents.api.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_peer_registry" {
  command = plan
  variables {
    foundation      = run.documents.cases.peer_registry.foundation
    foundation_json = run.documents.cases.peer_registry.foundation_json
    api             = run.documents.api.json-keys
  }
  expect_failures = [var.foundation_json]
}

run "reject_latest_source" {
  command = plan
  variables {
    foundation      = run.documents.cases.latest_source.foundation
    foundation_json = run.documents.cases.latest_source.foundation_json
    api             = run.documents.api.json-keys
  }
  expect_failures = [var.foundation_json]
}




run "reject_missing_private_project" {
  command = plan
  variables {
    foundation         = run.documents.cases.json-keys.foundation
    foundation_json    = run.documents.cases.json-keys.foundation_json
    api                = run.documents.api.json-keys
    private_project_id = null
  }
  expect_failures = [var.private_project_id]
}

run "reject_private_project_equals_api" {
  command = plan
  variables {
    foundation         = run.documents.cases.json-keys.foundation
    foundation_json    = run.documents.cases.json-keys.foundation_json
    api                = run.documents.api.json-keys
    private_project_id = "agora-public-api-test"
  }
  expect_failures = [var.private_project_id]
}

run "reject_peer_network" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    api             = run.documents.api.json-keys
    network         = { network = "projects/agora-peer-test/global/networks/agora-production", subnetwork = "projects/agora-peer-test/regions/europe-west1/subnetworks/agora-production-europe-west1" }
  }
  expect_failures = [var.network]
}

run "reject_private_image" {
  command = plan
  variables {
    foundation      = run.documents.cases.json-keys.foundation
    foundation_json = run.documents.cases.json-keys.foundation_json
    api             = merge(run.documents.api.json-keys, { image = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-production/service-json-keys/grpc@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" })
  }
  expect_failures = [var.api]
}


run "reject_missing_authentication" {
  command = plan
  variables {
    service         = "authentication"
    foundation      = run.documents.cases.authentication.foundation
    foundation_json = run.documents.cases.authentication.foundation_json
    api             = run.documents.api.authentication
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
    api             = run.documents.api.authentication
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
    api             = run.documents.api.authentication
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
    api             = run.documents.api.authentication
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
    api             = run.documents.api.authentication
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
    api             = run.documents.api.authentication
    authentication  = merge(run.documents.authentication, { smtp_username = "unsafe\nvalue" })
    secret_versions = { postgres-password = 17, smtp-sender-password = 21 }
  }
  expect_failures = [var.authentication]
}
