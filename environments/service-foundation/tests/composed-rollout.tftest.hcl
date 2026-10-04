mock_provider "google" {
  mock_data "google_project" { defaults = { number = "123456789012" } }
  mock_resource "google_service_account" {
    defaults = {
      email = "agora-json-keys-private@agora-private-test.iam.gserviceaccount.com"
      name  = "projects/agora-private-test/serviceAccounts/agora-json-keys-private@agora-private-test.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_monitoring_notification_channel" {
    defaults = { name = "projects/123456789012/notificationChannels/123456789" }
  }
  mock_resource "google_clouddeploy_delivery_pipeline" {
    defaults = { id = "projects/agora-private-test/locations/europe-west1/deliveryPipelines/agora-json-keys-grpc" }
  }
  mock_resource "google_clouddeploy_target" {
    defaults = { id = "projects/agora-private-test/locations/europe-west1/targets/agora-json-keys-grpc" }
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
  rollout = {
    verification_image = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    network            = "projects/agora-private-test/global/networks/agora-production"
    subnetwork         = "projects/agora-private-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
  }
}

run "documents" {
  command = apply
  module { source = "./tests/fixtures/handoff" }
}

run "private_json_keys_pipeline" {
  command = plan
  variables { database_handoff = run.documents.cases.json_keys }
  assert {
    condition = (
      output.rollout.pipeline == "projects/agora-private-test/locations/europe-west1/deliveryPipelines/agora-json-keys-grpc" &&
      output.rollout.target == "projects/agora-private-test/locations/europe-west1/targets/agora-json-keys-grpc" &&
      jsonencode(jsondecode(google_storage_bucket_object.coordinates.content).rollout) == jsonencode(output.rollout) &&
      jsonencode(jsondecode(google_storage_bucket_object.coordinates.content).database_source) == jsonencode(var.database_handoff.reference) &&
      jsondecode(google_storage_bucket_object.coordinates.content).database == jsondecode(var.database_handoff.document_json) &&
      length(google_compute_disk.database) == 0 && length(google_compute_instance_group_manager.database) == 0 &&
      length(google_compute_instance.repository) == 0 && length(module.job_access) == 0 &&
      output.database == null && output.pgbackrest_repository == null && output.native_bringup == null
    )
    error_message = "Publish the composed private pipeline and retained database reference without assuming host or application-job ownership."
  }
}

run "public_json_keys_pipeline" {
  command = plan
  variables {
    project_id       = "agora-api-test"
    zone             = "public-api"
    database_handoff = run.documents.cases.json_keys
    rollout = {
      verification_image = "europe-west1-docker.pkg.dev/agora-api-test/agora-json-keys-api-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      network            = "projects/agora-private-test/global/networks/agora-production"
      subnetwork         = "projects/agora-private-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
    }
  }
  override_resource {
    target = google_service_account.runtime
    values = {
      email = "agora-json-keys-api@agora-api-test.iam.gserviceaccount.com"
      name  = "projects/agora-api-test/serviceAccounts/agora-json-keys-api@agora-api-test.iam.gserviceaccount.com"
    }
  }
  override_resource {
    target = module.rollout["api"].google_clouddeploy_delivery_pipeline.service
    values = { id = "projects/agora-api-test/locations/europe-west1/deliveryPipelines/agora-json-keys-rest" }
  }
  override_resource {
    target = module.rollout["api"].google_clouddeploy_target.service
    values = { id = "projects/agora-api-test/locations/europe-west1/targets/agora-json-keys-rest" }
  }
  assert {
    condition = (
      output.rollout.pipeline == "projects/agora-api-test/locations/europe-west1/deliveryPipelines/agora-json-keys-rest" &&
      output.rollout.target == "projects/agora-api-test/locations/europe-west1/targets/agora-json-keys-rest" &&
      jsonencode(jsondecode(google_storage_bucket_object.coordinates.content).rollout) == jsonencode(output.rollout) &&
      jsondecode(google_storage_bucket_object.coordinates.content).database == jsondecode(var.database_handoff.document_json) &&
      toset(keys(google_secret_manager_secret_iam_member.runtime)) == toset(["production-json-keys-postgres-password"]) &&
      output.runtime.service_account == "agora-json-keys-api@agora-api-test.iam.gserviceaccount.com" &&
      output.database == null && length(module.job_access) == 0
    )
    error_message = "JSON Keys REST must use its own API pipeline and identity with the same private database, without the master key."
  }
}

run "public_authentication_pipeline" {
  command = plan
  variables {
    project_id       = "agora-api-test"
    service          = "authentication"
    zone             = "public-api"
    database_handoff = run.documents.cases.authentication
    rollout = {
      verification_image = "europe-west1-docker.pkg.dev/agora-api-test/agora-authentication-api-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      network            = "projects/agora-private-test/global/networks/agora-production"
      subnetwork         = "projects/agora-private-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
    }
  }
  override_resource {
    target = google_service_account.runtime
    values = {
      email = "agora-authentication-api@agora-api-test.iam.gserviceaccount.com"
      name  = "projects/agora-api-test/serviceAccounts/agora-authentication-api@agora-api-test.iam.gserviceaccount.com"
    }
  }
  override_resource {
    target = module.rollout["api"].google_clouddeploy_delivery_pipeline.service
    values = { id = "projects/agora-api-test/locations/europe-west1/deliveryPipelines/agora-authentication-rest" }
  }
  override_resource {
    target = module.rollout["api"].google_clouddeploy_target.service
    values = { id = "projects/agora-api-test/locations/europe-west1/targets/agora-authentication-rest" }
  }
  assert {
    condition = (
      output.rollout.pipeline == "projects/agora-api-test/locations/europe-west1/deliveryPipelines/agora-authentication-rest" &&
      output.rollout.target == "projects/agora-api-test/locations/europe-west1/targets/agora-authentication-rest" &&
      jsonencode(jsondecode(google_storage_bucket_object.coordinates.content).rollout) == jsonencode(output.rollout) &&
      jsondecode(google_storage_bucket_object.coordinates.content).database == jsondecode(var.database_handoff.document_json) &&
      output.runtime.service_account == "agora-authentication-api@agora-api-test.iam.gserviceaccount.com" &&
      output.database == null && length(module.job_access) == 0
    )
    error_message = "Authentication REST must compose its own API pipeline and retain its existing private database."
  }
}

run "reject_private_authentication_pipeline" {
  command = plan
  variables {
    service          = "authentication"
    database_handoff = run.documents.cases.authentication
    rollout = {
      verification_image = "europe-west1-docker.pkg.dev/agora-private-test/agora-authentication-private-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      network            = "projects/agora-private-test/global/networks/agora-production"
      subnetwork         = "projects/agora-private-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
    }
  }
  expect_failures = [var.rollout]
}

run "reject_peer_probe_network" {
  command = plan
  variables {
    database_handoff = run.documents.cases.json_keys
    rollout = {
      verification_image = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      network            = "projects/agora-peer-test/global/networks/agora-production"
      subnetwork         = "projects/agora-peer-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
    }
  }
  expect_failures = [google_service_account.runtime]
}
