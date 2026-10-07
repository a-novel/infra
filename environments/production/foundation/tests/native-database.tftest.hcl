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
    condition = length(module.native_backup) == 0 && length(google_project_iam_member.database_maintenance_iap) == 0 && alltrue([
      for template in google_compute_instance_template.database :
      template.metadata_startup_script == file("../../../assets/database-host/legacy-startup.sh")
    ])
    error_message = "Default inputs must leave both database templates unchanged."
  }
}

run "native_json_keys_reuses_existing_host" {
  command = plan
  variables {
    native_backups = { "json-keys" = {
      repository_ip     = "10.20.0.7"
      server_image      = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-production/service-json-keys/database@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      credentials_image = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-tooling/host-credentials@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      client_name       = "agora-database.agora-production-test"
      ca_version        = "1"
      identity_version  = "2"
      wal_archiving     = true
    } }
  }
  assert {
    condition = (
      keys(google_project_iam_member.database_maintenance_iap) == ["json-keys"] &&
      google_project_iam_member.database_maintenance_iap["json-keys"].role == "roles/iap.tunnelResourceAccessor" &&
      google_project_iam_member.database_maintenance_iap["json-keys"].member == "serviceAccount:infra-foundation@agora-management-test.iam.gserviceaccount.com" &&
      one(google_project_iam_member.database_maintenance_iap["json-keys"].condition).title == "NativeBackupMaintenanceSSH-json-keys"
    )
    error_message = "Native maintenance must grant conditional IAP access only to foundation for the enrolled service."
  }
  assert {
    condition = alltrue([
      google_compute_instance_template.database["json_keys"].metadata_startup_script == module.native_backup["json-keys"].startup_script,
      google_compute_instance_template.database["authentication"].metadata_startup_script == file("../../../assets/database-host/legacy-startup.sh"),
      length(google_compute_disk.database) == 2,
      length(google_compute_instance_group_manager.database) == 2,
      google_compute_instance_group_manager.database["json_keys"].target_size == 1,
      one(google_compute_instance_group_manager.database["json_keys"].stateful_disk).delete_rule == "NEVER",
      one(google_compute_instance_group_manager.database["json_keys"].update_policy).max_surge_fixed == 0,
      !contains(keys(google_compute_instance_template.database["json_keys"].metadata), "user-data"),
      strcontains(module.native_backup["json-keys"].startup_script, "systemctl start agora-database.service"),
      !strcontains(module.native_backup["json-keys"].startup_script, "systemctl start agora-backup"),
      !strcontains(module.native_backup["json-keys"].startup_script, "systemctl enable"),
    ])
    error_message = "Only JSON Keys boot changes; disk ownership, singleton capacity, Authentication and stopped timers remain."
  }
  assert {
    condition = alltrue([for option in [
      "--zone=private", "--management-project-number=123456789012", "Environment=PGBACKREST_WAL_ARCHIVING=true",
      "Environment=PGBACKREST_REPOSITORY_IP=10.20.0.7", "Environment=PGBACKREST_DATABASE_IMAGE=${var.native_backups["json-keys"].server_image}",
    ] : strcontains(yamldecode(module.native_backup["json-keys"].cloud_config).write_files[3].content, option)])
    error_message = "The shared native unit must bind exact identity, image, endpoint and credential scope."
  }
}

run "unregistered_native_is_rejected" {
  command = plan
  variables {
    pgbackrest_repository_services = []
    native_backups = { "json-keys" = {
      repository_ip     = "10.20.0.7"
      server_image      = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-production/service-json-keys/database@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      credentials_image = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-tooling/host-credentials@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      client_name       = "agora-database.agora-production-test"
      ca_version        = "1"
      identity_version  = "2"
    } }
  }
  expect_failures = [var.native_backups]
}

run "external_endpoint_is_rejected" {
  command = plan
  variables {
    native_backups = { "json-keys" = {
      repository_ip     = "203.0.113.1"
      server_image      = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-production/service-json-keys/database@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      credentials_image = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-tooling/host-credentials@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      client_name       = "agora-database.agora-production-test"
      ca_version        = "1"
      identity_version  = "2"
    } }
  }
  expect_failures = [var.native_backups]
}

run "authentication_uses_its_existing_host" {
  command = plan
  variables {
    service_release_zones          = { json-keys = ["private"], authentication = ["private"] }
    pgbackrest_repository_services = ["json-keys", "authentication"]
    native_backups = { authentication = {
      repository_ip     = "10.20.0.8"
      server_image      = "europe-west1-docker.pkg.dev/agora-production-test/agora-authentication-private-production/service-authentication/database@sha256:${sha256("database")}"
      credentials_image = "europe-west1-docker.pkg.dev/agora-production-test/agora-authentication-private-tooling/host-credentials@sha256:${sha256("credentials")}"
      client_name       = "agora-authentication-database.agora-production-test"
      ca_version        = "1"
      identity_version  = "1"
      wal_archiving     = true
    } }
  }
  assert {
    condition = alltrue([
      google_compute_instance_template.database["authentication"].metadata_startup_script == module.native_backup["authentication"].startup_script,
      google_compute_instance_template.database["json_keys"].metadata_startup_script == file("../../../assets/database-host/legacy-startup.sh"),
      length(google_compute_disk.database) == 2,
      google_compute_instance_group_manager.database["authentication"].target_size == 1,
      one(google_compute_instance_group_manager.database["authentication"].stateful_disk).delete_rule == "NEVER",
      one(google_compute_instance_group_manager.database["authentication"].update_policy).max_surge_fixed == 0,
      alltrue([for option in ["--service=authentication", "--name=agora-authentication-database.agora-production-test", "agora-postgres-authentication"] :
        strcontains(yamldecode(module.native_backup["authentication"].cloud_config).write_files[3].content, option)
      ]),
      alltrue([for option in ["[authentication]", "repo1-path=/authentication", "pg1-user=agora_authentication", "pg1-database=agora_authentication"] :
        strcontains(yamldecode(module.native_backup["authentication"].cloud_config).write_files[2].content, option)
      ]),
      alltrue([for file in yamldecode(module.native_backup["authentication"].cloud_config).write_files :
        alltrue([for option in ["--stanza=authentication", "container:agora-postgres-authentication", "source=/mnt/disks/agora-data/authentication"] : strcontains(file.content, option)])
        if startswith(file.path, "/etc/systemd/system/agora-backup-") && endswith(file.path, ".service")
      ]),
    ])
    error_message = "Authentication must select its own identity, stanza, SQL database and data mount on the same singleton host."
  }
}

run "authentication_rejects_peer_images" {
  command = plan
  variables {
    service_release_zones          = { authentication = ["private"] }
    pgbackrest_repository_services = ["authentication"]
    native_backups = { authentication = {
      repository_ip     = "10.20.0.8"
      server_image      = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-production/service-json-keys/database@sha256:${sha256("database")}"
      credentials_image = "europe-west1-docker.pkg.dev/agora-production-test/agora-json-keys-private-tooling/host-credentials@sha256:${sha256("credentials")}"
      client_name       = "agora-authentication-database.agora-production-test"
      ca_version        = "1"
      identity_version  = "1"
    } }
  }
  expect_failures = [var.native_backups]
}

run "reject_shared_tls_client_identity" {
  command = plan
  variables {
    service_release_zones          = { json-keys = ["private"], authentication = ["private"] }
    pgbackrest_repository_services = ["json-keys", "authentication"]
    native_backups = { for service in ["json-keys", "authentication"] : service => {
      repository_ip     = service == "json-keys" ? "10.20.0.7" : "10.20.0.8"
      server_image      = "europe-west1-docker.pkg.dev/agora-production-test/agora-${service}-private-production/service-${service}/database@sha256:${sha256("database")}"
      credentials_image = "europe-west1-docker.pkg.dev/agora-production-test/agora-${service}-private-tooling/host-credentials@sha256:${sha256("credentials")}"
      client_name       = "agora-database.agora-production-test"
      ca_version        = "1"
      identity_version  = "1"
    } }
  }
  expect_failures = [var.native_backups]
}
