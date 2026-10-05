mock_provider "google-beta" {
  mock_resource "google_project_service_identity" {
    defaults = { member = "serviceAccount:mock-agent@gcp-sa-cloudscheduler.iam.gserviceaccount.com" }
  }
}

mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email = "runtime-mock@agora-production-test.iam.gserviceaccount.com"
      name  = "projects/agora-production-test/serviceAccounts/runtime-mock@agora-production-test.iam.gserviceaccount.com"
    }
  }
}

variables {
  management_project_id                 = "agora-management-test"
  workload_project_id                   = "agora-production-test"
  adopt_default_network                 = false
  backup_bucket_name                    = "agora-management-test-123456789012-backups"
  billing_account_id                    = "ABCDEF-123456-ABCDEF"
  cost_alert_email                      = "infra@example.com"
  operations_alert_email                = "operations@example.com"
  organization_id                       = "123456789012"
  database_operator_principals          = ["group:infra-operators@example.com"]
  authentication_initializer_principals = ["group:authentication-initializers@example.com"]
  shared_vpc_enabled                    = true
  service_release_zones                 = { json-keys = ["private"] }
  pgbackrest_repository_services        = ["json-keys"]
}

run "default_preserves_existing_boot" {
  command = plan
  assert {
    condition = length(module.json_keys_native_backup) == 0 && alltrue([
      for template in google_compute_instance_template.database :
      template.metadata_startup_script == file("../../../assets/database-host/legacy-startup.sh")
    ])
    error_message = "Default inputs must leave both database templates unchanged."
  }
}

run "native_json_keys_reuses_existing_host" {
  command = plan
  variables {
    json_keys_native_backup = {
      repository_ip     = "10.20.0.7"
      server_image      = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-production/service-json-keys/database@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      credentials_image = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-tooling/host-credentials@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      ca_version        = "1"
      identity_version  = "2"
      wal_archiving     = true
    }
  }
  assert {
    condition = alltrue([
      google_compute_instance_template.database["json_keys"].metadata_startup_script == module.json_keys_native_backup[0].startup_script,
      google_compute_instance_template.database["authentication"].metadata_startup_script == file("../../../assets/database-host/legacy-startup.sh"),
      length(google_compute_disk.database) == 2,
      length(google_compute_instance_group_manager.database) == 2,
      google_compute_instance_group_manager.database["json_keys"].target_size == 1,
      one(google_compute_instance_group_manager.database["json_keys"].stateful_disk).delete_rule == "NEVER",
      one(google_compute_instance_group_manager.database["json_keys"].update_policy).max_surge_fixed == 0,
      !contains(keys(google_compute_instance_template.database["json_keys"].metadata), "user-data"),
      strcontains(module.json_keys_native_backup[0].startup_script, "systemctl start agora-database.service"),
      !strcontains(module.json_keys_native_backup[0].startup_script, "systemctl start agora-backup"),
      !strcontains(module.json_keys_native_backup[0].startup_script, "systemctl enable"),
    ])
    error_message = "Only JSON Keys boot changes; disk ownership, singleton capacity, Authentication and stopped timers remain."
  }
  assert {
    condition = alltrue([for option in [
      "--zone=private", "--management-project-number=123456789012", "Environment=PGBACKREST_WAL_ARCHIVING=true",
      "Environment=PGBACKREST_REPOSITORY_IP=10.20.0.7", "Environment=PGBACKREST_DATABASE_IMAGE=${var.json_keys_native_backup.server_image}",
    ] : strcontains(yamldecode(module.json_keys_native_backup[0].cloud_config).write_files[3].content, option)])
    error_message = "The shared native unit must bind exact identity, image, endpoint and credential scope."
  }
}

run "unregistered_native_is_rejected" {
  command = plan
  variables {
    pgbackrest_repository_services = []
    json_keys_native_backup = {
      repository_ip     = "10.20.0.7"
      server_image      = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-production/service-json-keys/database@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      credentials_image = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-tooling/host-credentials@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      ca_version        = "1"
      identity_version  = "2"
    }
  }
  expect_failures = [var.json_keys_native_backup]
}

run "external_endpoint_is_rejected" {
  command = plan
  variables {
    json_keys_native_backup = {
      repository_ip     = "203.0.113.1"
      server_image      = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-production/service-json-keys/database@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      credentials_image = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-tooling/host-credentials@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      ca_version        = "1"
      identity_version  = "2"
    }
  }
  expect_failures = [var.json_keys_native_backup]
}
