mock_provider "google" {
  mock_data "google_project" { defaults = { number = "123456789012" } }
  mock_data "google_compute_instance_group" {
    defaults = { instances = ["https://www.googleapis.com/compute/v1/projects/agora-json-keys-test/zones/europe-west1-b/instances/database-test"] }
  }
  mock_resource "google_service_account" {
    defaults = {
      email = "agora-database@agora-json-keys-test.iam.gserviceaccount.com"
      name  = "projects/agora-json-keys-test/serviceAccounts/agora-database@agora-json-keys-test.iam.gserviceaccount.com"
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
    cos_image  = "projects/cos-cloud/global/images/cos-129-19506-448-53"
  }
}

run "no_repository_by_default" {
  command = plan
  assert {
    condition = alltrue([
      length(google_compute_instance.repository) == 0,
      length(google_service_account.repository) == 0,
      length(google_service_account_iam_member.repository_attachment) == 0,
      output.pgbackrest_repository == null,
    ])
    error_message = "Existing database inputs must add no repository host, identity or attachment authority."
  }
}

run "private_stopped_repository" {
  command = plan
  variables { pgbackrest_repository = {} }
  override_resource {
    target = google_service_account.repository
    values = {
      email = "agora-backup-repository@agora-json-keys-test.iam.gserviceaccount.com"
      name  = "projects/agora-json-keys-test/serviceAccounts/agora-backup-repository@agora-json-keys-test.iam.gserviceaccount.com"
    }
  }

  assert {
    condition = { for key, host in google_compute_instance.repository : key => {
      project     = host.project
      zone        = host.zone
      machine     = host.machine_type
      status      = host.desired_status
      subnet      = host.network_interface[0].subnetwork
      public_ips  = length(host.network_interface[0].access_config)
      identity    = host.service_account[0].email
      boot        = [host.boot_disk[0].initialize_params[0].image, host.boot_disk[0].initialize_params[0].type, tostring(host.boot_disk[0].initialize_params[0].size)]
      data_disks  = length(host.attached_disk)
      secure_boot = host.shielded_instance_config[0].enable_secure_boot
      deletion    = host.deletion_protection
      } } == { host = {
      project     = var.project_id
      zone        = var.database.zone
      machine     = "e2-micro"
      status      = "TERMINATED"
      subnet      = var.database.subnetwork
      public_ips  = 0
      identity    = "agora-backup-repository@agora-json-keys-test.iam.gserviceaccount.com"
      boot        = [var.database.cos_image, "pd-standard", "20"]
      data_disks  = 0
      secure_boot = true
      deletion    = true
    } }
    error_message = "Keep one stopped private micro VM, dedicated identity and boot disk, with no database disk."
  }

  assert {
    condition = alltrue([
      google_service_account.repository["host"].account_id == "agora-backup-repository",
      google_service_account.repository["host"].project == var.project_id,
      google_service_account_iam_member.repository_attachment["host"].service_account_id == google_service_account.repository["host"].name,
      google_service_account_iam_member.repository_attachment["host"].member == "serviceAccount:infra-foundation@agora-management-test.iam.gserviceaccount.com",
      google_service_account_iam_member.repository_attachment["host"].role == "roles/iam.serviceAccountUser",
      google_compute_instance.repository["host"].metadata["enable-guest-attributes"] == "FALSE",
      google_compute_instance.repository["host"].metadata_startup_script == null,
      !contains(keys(google_compute_instance.repository["host"].metadata), "startup-script"),
      alltrue([for binding in google_secret_manager_secret_iam_member.database : binding.member != "serviceAccount:${google_service_account.repository["host"].email}"]),
      output.pgbackrest_repository.service_account == google_service_account.repository["host"].email,
    ])
    error_message = "Foundation attaches the exact repository identity; it receives no database secret or readiness payload."
  }
}

run "reject_missing_database" {
  command = plan
  variables {
    database              = null
    pgbackrest_repository = {}
  }
  expect_failures = [var.pgbackrest_repository]
}

run "reject_unreviewed_service" {
  command = plan
  variables {
    service               = "authentication"
    pgbackrest_repository = {}
  }
  expect_failures = [var.pgbackrest_repository]
}

run "reject_unbounded_profile" {
  command = plan
  variables { pgbackrest_repository = { machine_type = "e2-standard-8" } }
  expect_failures = [var.pgbackrest_repository]
}
