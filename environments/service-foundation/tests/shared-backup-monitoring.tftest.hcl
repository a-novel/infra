mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = { email = "runtime@agora-private-test.iam.gserviceaccount.com", name = "projects/agora-private-test/serviceAccounts/runtime@agora-private-test.iam.gserviceaccount.com" }
  }
  mock_resource "google_monitoring_notification_channel" {
    defaults = { name = "projects/123456789012/notificationChannels/123456789" }
  }
  mock_data "google_compute_instance_group" {
    defaults = { instances = ["https://www.googleapis.com/compute/v1/projects/agora-private-test/zones/europe-west1-b/instances/agora-database-json-keys-test"] }
  }
  mock_data "google_compute_instance" {
    defaults = { instance_id = "123456789" }
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
  pgbackrest_repository = {
    placement = {
      zone       = "europe-west1-b"
      subnetwork = "projects/agora-private-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
      cos_image  = "projects/cos-cloud/global/images/cos-129-19506-505-8"
    }
    runtime = merge(jsondecode(file("tests/fixtures/repository-runtime.json")), {
      server_image      = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-production/service-json-keys/database@sha256:${sha256("server")}"
      credentials_image = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-tooling/host-credentials@sha256:${sha256("credentials")}"
    })
  }
}

run "documents" {
  command = apply
  module { source = "./tests/fixtures/handoff" }
}

run "unenrolled_by_default" {
  command = plan
  variables { database_handoff = run.documents.cases.json_keys }
  assert {
    condition = alltrue([
      length(data.google_compute_instance_group.shared_backup_database) == 0,
      length(google_logging_metric.database_backup_success) == 0,
      length(google_monitoring_alert_policy.database_backup_failure) == 0,
      length(google_monitoring_alert_policy.database_backup_health) == 0,
    ])
    error_message = "Existing shared repository configuration must not silently enroll monitoring."
  }
}

run "prepare_without_database_ownership" {
  command = plan
  variables {
    database_handoff             = run.documents.cases.json_keys
    shared_backup_alerts_enabled = false
  }
  assert {
    condition = alltrue([
      data.google_compute_instance_group.shared_backup_database["host"].name == "agora-database-json-keys",
      data.google_compute_instance_group.shared_backup_database["host"].project == var.project_id,
      data.google_compute_instance_group.shared_backup_database["host"].zone == "europe-west1-b",
      strcontains(google_logging_metric.database_backup_success["host"].filter, "resource.labels.instance_id=\"123456789\""),
      google_logging_metric.database_backup_success["host"].project == var.project_id,
      !google_monitoring_alert_policy.database_backup_failure["host"].enabled,
      toset(keys(google_monitoring_alert_policy.database_backup_health)) == toset(["full", "backup", "check", "disk"]),
      alltrue([for policy in google_monitoring_alert_policy.database_backup_health :
        !policy.enabled && policy.notification_channels == tolist([google_monitoring_notification_channel.operations.name])
      ]),
      length(google_compute_disk.database) == 0,
      length(google_compute_instance_group_manager.database) == 0,
      length(module.database_runtime) == 0,
      output.database == null && output.native_bringup == null,
      google_compute_instance.repository["host"].desired_status == "TERMINATED",
    ])
    error_message = "Reuse native policies and the existing email channel without claiming or starting either host."
  }
}

run "enable_existing_native_policies" {
  command = plan
  variables {
    database_handoff             = run.documents.cases.json_keys
    shared_backup_alerts_enabled = true
  }
  assert {
    condition = google_monitoring_alert_policy.database_backup_failure["host"].enabled && alltrue([
      for policy in google_monitoring_alert_policy.database_backup_health :
      policy.enabled && strcontains(policy.conditions[0].condition_prometheus_query_language[0].query, "instance_id=\"123456789\"")
    ])
    error_message = "Explicit enrollment must enable all five native policies for the observed singleton, including never-seen success and missing disk telemetry."
  }
  assert {
    condition = alltrue([
      strcontains(local.database_backup_health_rules.disk.query, "compute.googleapis.com/guest/disk/bytes_used"),
      !strcontains(local.database_backup_health_rules.disk.query, "percent_used"),
      strcontains(local.database_backup_health_rules.disk.query, "mount_option=~\"(^|.*,)noatime(,.*|$)\""),
      strcontains(local.database_backup_health_rules.disk.query, "100 * sum by (device_name)"),
      length(regexall("absent_over_time", local.database_backup_health_rules.disk.query)) == 2,
    ])
    error_message = "Use the built-in collector's used/free byte series and detect either missing data-disk state; boot telemetry must not mask its absence."
  }
}

run "authentication_monitoring_is_service_scoped" {
  command = plan
  variables {
    service                      = "authentication"
    database_handoff             = run.documents.cases.authentication
    shared_backup_alerts_enabled = true
    pgbackrest_repository = {
      placement = run.documents.repository_placement
      runtime = merge(jsondecode(file("tests/fixtures/repository-runtime.json")), {
        server_image      = "europe-west1-docker.pkg.dev/agora-private-test/agora-authentication-private-production/service-authentication/database@sha256:${sha256("server")}"
        credentials_image = "europe-west1-docker.pkg.dev/agora-private-test/agora-authentication-private-tooling/host-credentials@sha256:${sha256("credentials")}"
        client_name       = "agora-authentication-database.agora-private-test"
      })
    }
  }
  override_data {
    target = data.google_compute_instance_group.shared_backup_database["host"]
    values = { instances = ["https://www.googleapis.com/compute/v1/projects/agora-private-test/zones/europe-west1-b/instances/agora-database-authentication-test"] }
  }
  override_data {
    target = data.google_compute_instance.shared_backup_database["host"]
    values = { instance_id = "987654321" }
  }
  assert {
    condition = alltrue([
      data.google_compute_instance_group.shared_backup_database["host"].name == "agora-database-authentication",
      google_logging_metric.database_backup_success["host"].name == "agora_authentication_backup_success",
      strcontains(google_logging_metric.database_backup_success["host"].filter, "resource.labels.instance_id=\"987654321\""),
      google_monitoring_alert_policy.database_backup_failure["host"].display_name == "Agora authentication native backup failed",
      alltrue([for policy in google_monitoring_alert_policy.database_backup_health :
        policy.enabled && strcontains(policy.conditions[0].condition_prometheus_query_language[0].query, "instance_id=\"987654321\"")
      ]),
      length(google_compute_disk.database) == 0,
      length(google_compute_instance_group_manager.database) == 0,
    ])
    error_message = "Authentication policies must observe its own singleton, not JSON Keys, without changing database ownership."
  }
}

run "reject_empty_database_group" {
  command = plan
  variables {
    database_handoff             = run.documents.cases.json_keys
    shared_backup_alerts_enabled = true
  }
  override_data {
    target = data.google_compute_instance_group.shared_backup_database["host"]
    values = { instances = [] }
  }
  expect_failures = [data.google_compute_instance_group.shared_backup_database]
}

run "reject_missing_repository" {
  command = plan
  variables {
    database_handoff             = run.documents.cases.json_keys
    pgbackrest_repository        = null
    shared_backup_alerts_enabled = true
  }
  expect_failures = [var.shared_backup_alerts_enabled]
}

run "reject_public_monitoring" {
  command = plan
  variables {
    zone                         = "public-api"
    project_id                   = "agora-public-api-test"
    database_handoff             = run.documents.cases.json_keys
    pgbackrest_repository        = null
    shared_backup_alerts_enabled = true
  }
  expect_failures = [var.shared_backup_alerts_enabled]
}

run "reject_multiple_database_hosts" {
  command = plan
  variables {
    database_handoff             = run.documents.cases.json_keys
    shared_backup_alerts_enabled = true
  }
  override_data {
    target = data.google_compute_instance_group.shared_backup_database["host"]
    values = { instances = [
      "https://www.googleapis.com/compute/v1/projects/agora-private-test/zones/europe-west1-b/instances/agora-database-json-keys-test",
      "https://www.googleapis.com/compute/v1/projects/agora-private-test/zones/europe-west1-b/instances/agora-database-json-keys-peer",
    ] }
  }
  expect_failures = [data.google_compute_instance_group.shared_backup_database]
}
