mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = { email = "runtime@agora-private-test.iam.gserviceaccount.com", name = "projects/agora-private-test/serviceAccounts/runtime@agora-private-test.iam.gserviceaccount.com" }
  }
  mock_resource "google_monitoring_notification_channel" {
    defaults = { name = "projects/123456789012/notificationChannels/123456789" }
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
}

run "documents" {
  command = apply
  module { source = "./tests/fixtures/handoff" }
}

run "json_keys_private_handoff" {
  command = plan
  variables {
    service          = "json-keys"
    zone             = "private"
    project_id       = "agora-private-test"
    database_handoff = run.documents.cases.json_keys
  }
  assert {
    condition = (
      length(google_cloud_run_v2_service_iam_member.json_keys_invoker) == 1 &&
      google_cloud_run_v2_service_iam_member.json_keys_invoker[0].project == "agora-private-test" &&
      google_cloud_run_v2_service_iam_member.json_keys_invoker[0].location == "europe-west1" &&
      google_cloud_run_v2_service_iam_member.json_keys_invoker[0].name == "agora-json-keys-grpc" &&
      google_cloud_run_v2_service_iam_member.json_keys_invoker[0].role == "roles/run.servicesInvoker" &&
      google_cloud_run_v2_service_iam_member.json_keys_invoker[0].member == "serviceAccount:${google_service_account.runtime.email}" &&
      jsondecode(google_storage_bucket_object.coordinates.content).database == jsondecode(var.database_handoff.document_json) &&
      jsondecode(google_storage_bucket_object.coordinates.content).database.schema_version == 2 &&
      jsonencode(jsondecode(google_storage_bucket_object.coordinates.content).database_source) == jsonencode(var.database_handoff.reference) &&
      length(google_compute_disk.database) == 0 && length(google_compute_instance_group_manager.database) == 0 &&
      length(google_compute_instance.repository) == 0 && length(module.job_access) == 0 &&
      output.database == null && output.pgbackrest_repository == null && output.native_bringup == null
    )
    error_message = "Handoff must publish only the selected endpoint and source without acquiring host, backup or job ownership."
  }
}

run "json_keys_public_api_handoff" {
  command = plan
  variables {
    service          = "json-keys"
    zone             = "public-api"
    project_id       = "agora-api-test"
    database_handoff = run.documents.cases.json_keys
  }
  assert {
    condition = (
      length(google_cloud_run_v2_service_iam_member.json_keys_invoker) == 0 &&
      jsondecode(google_storage_bucket_object.coordinates.content).database == jsondecode(var.database_handoff.document_json) &&
      jsondecode(google_storage_bucket_object.coordinates.content).database.schema_version == 2 &&
      jsonencode(jsondecode(google_storage_bucket_object.coordinates.content).database_source) == jsonencode(var.database_handoff.reference) &&
      length(google_compute_disk.database) == 0 && length(google_compute_instance_group_manager.database) == 0 &&
      length(google_compute_instance.repository) == 0 && length(module.job_access) == 0 &&
      output.database == null && output.pgbackrest_repository == null && output.native_bringup == null
    )
    error_message = "Handoff must publish only the selected endpoint and source without acquiring host, backup or job ownership."
  }
}

run "authentication_private_handoff" {
  command = plan
  variables {
    service          = "authentication"
    zone             = "private"
    project_id       = "agora-private-test"
    database_handoff = run.documents.cases.authentication
  }
  assert {
    condition = (
      length(google_cloud_run_v2_service_iam_member.json_keys_invoker) == 0 &&
      jsondecode(google_storage_bucket_object.coordinates.content).database == jsondecode(var.database_handoff.document_json) &&
      jsondecode(google_storage_bucket_object.coordinates.content).database.schema_version == 2 &&
      jsonencode(jsondecode(google_storage_bucket_object.coordinates.content).database_source) == jsonencode(var.database_handoff.reference) &&
      length(google_compute_disk.database) == 0 && length(google_compute_instance_group_manager.database) == 0 &&
      length(google_compute_instance.repository) == 0 && length(module.job_access) == 0 &&
      output.database == null && output.pgbackrest_repository == null && output.native_bringup == null
    )
    error_message = "Handoff must publish only the selected endpoint and source without acquiring host, backup or job ownership."
  }
}

run "authentication_public_api_handoff" {
  command = plan
  variables {
    service          = "authentication"
    zone             = "public-api"
    project_id       = "agora-api-test"
    database_handoff = run.documents.cases.authentication
  }
  assert {
    condition = (
      length(google_cloud_run_v2_service_iam_member.json_keys_invoker) == 1 &&
      google_cloud_run_v2_service_iam_member.json_keys_invoker[0].project == "agora-private-test" &&
      google_cloud_run_v2_service_iam_member.json_keys_invoker[0].location == "europe-west1" &&
      google_cloud_run_v2_service_iam_member.json_keys_invoker[0].name == "agora-json-keys-grpc" &&
      google_cloud_run_v2_service_iam_member.json_keys_invoker[0].role == "roles/run.servicesInvoker" &&
      google_cloud_run_v2_service_iam_member.json_keys_invoker[0].member == "serviceAccount:${google_service_account.runtime.email}"
    )
    error_message = "Authentication public-api may invoke only the existing private JSON Keys service using its own runtime identity."
  }
  assert {
    condition = (
      jsondecode(google_storage_bucket_object.coordinates.content).database == jsondecode(var.database_handoff.document_json) &&
      jsondecode(google_storage_bucket_object.coordinates.content).database.schema_version == 2 &&
      jsonencode(jsondecode(google_storage_bucket_object.coordinates.content).database_source) == jsonencode(var.database_handoff.reference) &&
      length(google_compute_disk.database) == 0 && length(google_compute_instance_group_manager.database) == 0 &&
      length(google_compute_instance.repository) == 0 && length(module.job_access) == 0 &&
      output.database == null && output.pgbackrest_repository == null && output.native_bringup == null
    )
    error_message = "Handoff must publish only the selected endpoint and source without acquiring host, backup or job ownership."
  }
}

run "reject_peer_service" {
  command = plan
  variables { database_handoff = run.documents.cases.peer_service }
  expect_failures = [var.database_handoff]
}

run "reject_peer_project" {
  command = plan
  variables { database_handoff = run.documents.cases.peer_project }
  expect_failures = [var.database_handoff]
}

run "reject_peer_zone" {
  command = plan
  variables { database_handoff = run.documents.cases.peer_zone }
  expect_failures = [var.database_handoff]
}

run "reject_peer_port" {
  command = plan
  variables { database_handoff = run.documents.cases.peer_port }
  expect_failures = [var.database_handoff]
}

run "reject_schema" {
  command = plan
  variables { database_handoff = run.documents.cases.schema }
  expect_failures = [var.database_handoff]
}

run "reject_public_ip" {
  command = plan
  variables { database_handoff = run.documents.cases.public_ip }
  expect_failures = [var.database_handoff]
}

run "reject_invalid_ip" {
  command = plan
  variables { database_handoff = run.documents.cases.invalid_ip }
  expect_failures = [var.database_handoff]
}

run "reject_malformed" {
  command = plan
  variables { database_handoff = run.documents.cases.malformed }
  expect_failures = [var.database_handoff]
}

run "reject_extra_field" {
  command = plan
  variables { database_handoff = run.documents.cases.extra_field }
  expect_failures = [var.database_handoff]
}

run "reject_wrong_private_project" {
  command = plan
  variables { database_handoff = merge(run.documents.cases.json_keys, { private_project_id = "agora-peer-test" }) }
  expect_failures = [var.database_handoff]
}

run "reject_changed_bytes" {
  command = plan
  variables { database_handoff = merge(run.documents.cases.json_keys, { document_json = "${run.documents.cases.json_keys.document_json} " }) }
  expect_failures = [var.database_handoff]
}

run "reject_wrong_bucket" {
  command = plan
  variables { database_handoff = merge(run.documents.cases.json_keys, { reference = merge(run.documents.cases.json_keys.reference, { bucket = "agora-peer-test-123456789012-tofu-state" }) }) }
  expect_failures = [var.database_handoff]
}

run "reject_latest_generation" {
  command = plan
  variables { database_handoff = merge(run.documents.cases.json_keys, { reference = merge(run.documents.cases.json_keys.reference, { generation = "latest" }) }) }
  expect_failures = [var.database_handoff]
}

run "reject_wrong_namespace" {
  command = plan
  variables { database_handoff = merge(run.documents.cases.json_keys, { reference = merge(run.documents.cases.json_keys.reference, { object = "foundation/coordinates/agora-private-test/${run.documents.cases.json_keys.reference.sha256}.json" }) }) }
  expect_failures = [var.database_handoff]
}

run "reject_reference_schema" {
  command = plan
  variables { database_handoff = merge(run.documents.cases.json_keys, { reference = merge(run.documents.cases.json_keys.reference, { schema_version = 1 }) }) }
  expect_failures = [var.database_handoff]
}

run "reject_dedicated_handoff" {
  command = plan
  variables {
    zone             = null
    database_handoff = run.documents.cases.json_keys
  }
  expect_failures = [var.database_handoff]
}

run "reject_api_database_owner" {
  command = plan
  variables {
    zone             = "public-api"
    database_handoff = run.documents.cases.json_keys
  }
  expect_failures = [var.database_handoff]
}
