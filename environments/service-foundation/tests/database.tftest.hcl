mock_provider "google" {
  mock_data "google_project" { defaults = { number = "123456789012" } }
  mock_data "google_compute_instance_group" {
    defaults = { instances = ["https://www.googleapis.com/compute/v1/projects/agora-json-keys-test/zones/europe-west1-b/instances/database-test"] }
  }
  mock_resource "google_service_account" {
    defaults = {
      email = "agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com"
      name  = "projects/agora-json-keys-test/serviceAccounts/agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_monitoring_notification_channel" {
    defaults = { name = "projects/123456789012/notificationChannels/123456789" }
  }
}

variables {
  state_bucket           = "agora-management-test-123456789012-tofu-state"
  project_id             = "agora-json-keys-test"
  service                = "json-keys"
  management_project_id  = "agora-management-test"
  region                 = "europe-west1"
  operations_alert_email = "operations@example.test"
  database = {
    zone       = "europe-west1-b"
    subnetwork = "projects/agora-network-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
    cos_image  = "projects/cos-cloud/global/images/cos-125-19216-532-123"
  }
}

run "database_is_opt_in" {
  command = plan
  variables { database = null }
  assert {
    condition = output.database == null && alltrue([
      length(google_compute_disk.database) == 0,
      length(google_compute_instance_group_manager.database) == 0,
      length(google_service_account.database) == 0,
      length(google_secret_manager_secret_iam_member.database) == 0,
    ])
    error_message = "Default inputs must create neither a host nor its credential authority."
  }
}

run "json_keys_private_idle_host" {
  command = plan
  override_resource {
    target = google_service_account.database
    values = {
      email = "agora-database@agora-json-keys-test.iam.gserviceaccount.com"
      name  = "projects/agora-json-keys-test/serviceAccounts/agora-database@agora-json-keys-test.iam.gserviceaccount.com"
    }
  }
  assert {
    condition = { for key, disk in google_compute_disk.database : key => {
      project = disk.project, zone = disk.zone, name = disk.name, type = disk.type, size = disk.size, deletion = disk.deletion_policy,
      } } == { host = {
      project = var.project_id, zone = var.database.zone, name = "agora-data-json-keys", type = "pd-balanced", size = 50, deletion = "PREVENT",
    } }
    error_message = "Only the selected service receives a deletion-protected SSD-backed disk."
  }
  assert {
    condition = { for key, template in google_compute_instance_template.database : key => {
      machine     = template.machine_type, subnetwork = template.network_interface[0].subnetwork,
      public_ips  = length(template.network_interface[0].access_config), identity = template.service_account[0].email,
      secure_boot = template.shielded_instance_config[0].enable_secure_boot, tags = template.tags,
      data_disks  = { for disk in template.disk : disk.device_name => disk.auto_delete if !disk.boot },
      } } == { host = {
      machine  = "e2-medium", subnetwork = var.database.subnetwork, public_ips = 0,
      identity = google_service_account.database["host"].email, secure_boot = true,
      tags     = toset(["agora-database-json-keys"]), data_disks = { agora-data = false },
    } }
    error_message = "Keep a private hardened singleton host, dedicated identity and separately preserved data disk."
  }
  assert {
    condition = { for key, group in google_compute_instance_group_manager.database : key => {
      count  = group.target_size, deletion = group.deletion_policy,
      disks  = { for disk in group.stateful_disk : disk.device_name => disk.delete_rule },
      ips    = { for ip in group.stateful_internal_ip : ip.interface_name => ip.delete_rule },
      policy = [group.update_policy[0].type, group.update_policy[0].replacement_method],
      surge  = group.update_policy[0].max_surge_fixed,
      } } == { host = {
      count  = 1, deletion = "PREVENT", disks = { agora-data = "NEVER" }, ips = { nic0 = "NEVER" },
      policy = ["OPPORTUNISTIC", "RECREATE"], surge = 0,
    } }
    error_message = "Persist the disk/IP and forbid automatic rolling replacement or a second writer."
  }
  assert {
    condition = google_compute_instance_group_manager.database["host"].all_instances_config[0].metadata == tomap({
      agora-json-keys-database-image                   = ""
      agora-json-keys-postgres-password-version        = "0"
      agora-json-keys-postgres-backup-password-version = "0"
      agora-database-release-revision                  = ""
    })
    error_message = "Foundation must leave the database idle without selecting credentials or a release."
  }
  assert {
    condition = { for secret, binding in google_secret_manager_secret_iam_member.database : secret => [binding.project, binding.role, binding.member] } == {
      for secret in ["production-json-keys-postgres-password", "production-json-keys-postgres-backup-password"] : secret =>
      [var.management_project_id, "roles/secretmanager.secretAccessor", "serviceAccount:${google_service_account.database["host"].email}"]
    }
    error_message = "The host can read only its owner's and backup reader's credentials, never peer/master/SMTP/initializer secrets."
  }
  assert {
    condition = { for owner, binding in google_service_account_iam_member.database_attachment : owner => [binding.service_account_id, binding.role, binding.member] } == {
      for owner, account in {
        foundation = "infra-foundation@agora-management-test.iam.gserviceaccount.com",
        mig        = "123456789012@cloudservices.gserviceaccount.com",
      } : owner => [google_service_account.database["host"].name, "roles/iam.serviceAccountUser", "serviceAccount:${account}"]
    }
    error_message = "Only foundation and the selected project's MIG agent attach the database identity."
  }
  assert {
    condition = toset(keys(google_project_iam_member.database_telemetry)) == toset(["roles/logging.logWriter", "roles/monitoring.metricWriter"]) && [
      google_artifact_registry_repository_iam_member.database["host"].project,
      google_artifact_registry_repository_iam_member.database["host"].repository,
      google_artifact_registry_repository_iam_member.database["host"].role,
      google_artifact_registry_repository_iam_member.database["host"].member,
    ] == [var.project_id, "agora-production", "roles/artifactregistry.reader", "serviceAccount:${google_service_account.database["host"].email}"]
    error_message = "The host reports telemetry and reads owned images without registry writes or backup-object access."
  }
  assert {
    condition = [
      google_compute_resource_policy.database["host"].snapshot_schedule_policy[0].retention_policy[0].max_retention_days,
      google_compute_resource_policy.database["host"].snapshot_schedule_policy[0].retention_policy[0].on_source_disk_delete,
      google_compute_disk_resource_policy_attachment.database["host"].disk,
    ] == [7, "KEEP_AUTO_SNAPSHOTS", "agora-data-json-keys"]
    error_message = "Retain local crash-consistent snapshots independently of source-disk deletion."
  }
  assert {
    condition = [output.database.schema_version, output.database.project_id, output.database.service, output.database.group, output.database.port] == [
      1, var.project_id, "json-keys", "agora-database-json-keys", 5432,
    ]
    error_message = "Publish minimal selected-host coordinates, not peer state or credentials."
  }
}

run "authentication_uses_its_own_contract" {
  command = plan
  variables {
    service    = "authentication"
    project_id = "agora-authentication-test"
  }
  override_resource {
    target = google_service_account.database
    values = {
      email = "agora-database@agora-authentication-test.iam.gserviceaccount.com"
      name  = "projects/agora-authentication-test/serviceAccounts/agora-database@agora-authentication-test.iam.gserviceaccount.com"
    }
  }
  assert {
    condition = toset(keys(google_secret_manager_secret_iam_member.database)) == toset([
      "production-authentication-postgres-password", "production-authentication-postgres-backup-password",
      ]) && [google_compute_disk.database["host"].project, google_compute_disk.database["host"].name, output.database.port] == [
      var.project_id, "agora-data-authentication", 5433,
    ]
    error_message = "Authentication gets its own database contract, not JSON Keys credentials/storage/port."
  }
}

run "reject_zone_outside_region" {
  command = plan
  variables {
    database = {
      zone       = "europe-west2-a"
      subnetwork = "projects/agora-network-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
      cos_image  = "projects/cos-cloud/global/images/cos-125-19216-532-123"
    }
  }
  expect_failures = [var.database]
}
run "reject_floating_image" {
  command = plan
  variables {
    database = {
      zone       = "europe-west1-b"
      subnetwork = "projects/agora-network-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
      cos_image  = "projects/cos-cloud/global/images/family/cos-stable"
    }
  }
  expect_failures = [var.database]
}
run "reject_unknown_capacity" {
  command = plan
  variables {
    database = {
      zone         = "europe-west1-b"
      subnetwork   = "projects/agora-network-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
      cos_image    = "projects/cos-cloud/global/images/cos-125-19216-532-123"
      machine_type = "e2-small"
    }
  }
  expect_failures = [var.database]
}
run "reserve_host_memory" {
  command = plan
  variables {
    database = {
      zone                = "europe-west1-b"
      subnetwork          = "projects/agora-network-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
      cos_image           = "projects/cos-cloud/global/images/cos-125-19216-532-123"
      container_memory_mb = 4096
    }
  }
  expect_failures = [var.database]
}
run "reserve_host_cpu" {
  command = plan
  variables {
    database = {
      zone          = "europe-west1-b"
      subnetwork    = "projects/agora-network-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
      cos_image     = "projects/cos-cloud/global/images/cos-125-19216-532-123"
      container_cpu = 2
    }
  }
  expect_failures = [var.database]
}
run "reject_mismatched_rollout_subnet" {
  command = plan
  variables {
    rollout = {
      verification_image = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      network            = "projects/agora-network-test/global/networks/agora-production"
      subnetwork         = "projects/agora-network-test/regions/europe-west1/subnetworks/another-subnet"
    }
  }
  expect_failures = [var.database]
}
