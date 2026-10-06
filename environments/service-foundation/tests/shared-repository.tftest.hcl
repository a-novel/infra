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
  pgbackrest_repository = {
    placement = {
      zone       = "europe-west1-b"
      subnetwork = "projects/agora-private-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
      cos_image  = "projects/cos-cloud/global/images/cos-129-19506-505-8"
    }
  }
}

run "documents" {
  command = apply
  module { source = "./tests/fixtures/handoff" }
}

run "independent_stopped_repository" {
  command = plan
  variables { database_handoff = run.documents.cases.json_keys }
  assert {
    condition = alltrue([
      length(google_compute_instance.repository) == 1,
      google_compute_instance.repository["host"].desired_status == "TERMINATED",
      google_compute_instance.repository["host"].machine_type == "e2-micro",
      google_compute_instance.repository["host"].zone == "europe-west1-b",
      google_compute_instance.repository["host"].network_interface[0].subnetwork == var.pgbackrest_repository.placement.subnetwork,
      length(google_compute_instance.repository["host"].network_interface[0].access_config) == 0,
      length(google_compute_instance.repository["host"].attached_disk) == 0,
      google_compute_instance.repository["host"].boot_disk[0].initialize_params[0].size == 20,
      google_compute_instance.repository["host"].boot_disk[0].initialize_params[0].type == "pd-standard",
      google_compute_instance.repository["host"].boot_disk[0].initialize_params[0].image == var.pgbackrest_repository.placement.cos_image,
      google_compute_instance.repository["host"].deletion_protection,
      google_service_account.repository["host"].account_id == "agora-pgbr-json-keys",
      google_compute_instance.repository["host"].service_account[0].email == google_service_account.repository["host"].email,
      google_service_account_iam_member.repository_attachment["host"].role == "roles/iam.serviceAccountUser",
      google_service_account_iam_member.repository_attachment["host"].member == "serviceAccount:infra-foundation@agora-management-test.iam.gserviceaccount.com",
      !contains(keys(google_compute_instance.repository["host"].metadata), "user-data"),
      google_compute_instance.repository["host"].metadata_startup_script == null,
      length(google_artifact_registry_repository_iam_member.repository_images) == 0,
      length(google_project_iam_member.repository_maintenance_iap) == 0,
      length(google_compute_disk.database) == 0,
      length(google_compute_instance_template.database) == 0,
      length(google_compute_instance_group_manager.database) == 0,
      length(module.job_access) == 0,
      output.database == null && output.native_bringup == null,
      jsondecode(google_storage_bucket_object.coordinates.content).database == jsondecode(var.database_handoff.document_json),
      output.pgbackrest_repository.zone == "europe-west1-b",
    ])
    error_message = "Provision only the private stopped repository and attachment identity while preserving the external database handoff."
  }
}

run "reject_missing_handoff" {
  command         = plan
  expect_failures = [var.pgbackrest_repository]
}

run "reject_public_repository" {
  command = plan
  variables {
    zone             = "public-api"
    project_id       = "agora-api-test"
    database_handoff = run.documents.cases.json_keys
  }
  expect_failures = [var.pgbackrest_repository]
}

run "reject_peer_repository" {
  command = plan
  variables {
    service          = "authentication"
    database_handoff = run.documents.cases.authentication
  }
  expect_failures = [var.pgbackrest_repository]
}

run "prepared_runtime_stays_stopped" {
  command = plan
  override_resource {
    target = google_compute_instance.repository
    values = { network_interface = { network_ip = "10.90.0.3" } }
  }
  variables {
    database_handoff = run.documents.cases.json_keys
    pgbackrest_repository = {
      placement = run.documents.repository_placement
      runtime = merge(jsondecode(file("tests/fixtures/repository-runtime.json")), {
        server_image      = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-production/service-json-keys/database@sha256:${sha256("server")}"
        credentials_image = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-tooling/host-credentials@sha256:${sha256("credentials")}"
      })
    }
  }
  assert {
    condition = alltrue([
      google_compute_instance.repository["host"].desired_status == "TERMINATED",
      google_compute_instance.repository["host"].metadata["user-data"] == local.repository_cloud_config.host,
      yamldecode(local.repository_cloud_config.host).runcmd == [["systemctl", "daemon-reload"]],
      length(google_compute_instance_group_manager.database) == 0,
      length(google_compute_disk.database) == 0,
      output.native_bringup == null,
      jsondecode(google_storage_bucket_object.coordinates.content).database == jsondecode(var.database_handoff.document_json),
      alltrue([for key, binding in google_artifact_registry_repository_iam_member.repository_images :
        binding.repository == google_artifact_registry_repository.images[key].repository_id &&
        binding.member == "serviceAccount:${google_service_account.repository["host"].email}" &&
        binding.role == "roles/artifactregistry.reader"
      ]),
      length(google_artifact_registry_repository_iam_member.shared_database_images) == 2,
      alltrue([for binding in google_artifact_registry_repository_iam_member.shared_database_images :
        binding.member == "serviceAccount:agora-json-keys-database@agora-private-test.iam.gserviceaccount.com" &&
        binding.role == "roles/artifactregistry.reader"
      ]),
      strcontains(yamldecode(local.repository_cloud_config.host).write_files[2].content, "--endpoint=repository --zone=private "),
    ])
    error_message = "Shared runtime preparation installs a disabled unit and exact image-reader grants without starting or taking ownership of either database."
  }
  assert {
    condition = alltrue([
      length(google_project_iam_member.repository_maintenance_iap) == 1,
      google_project_iam_member.repository_maintenance_iap["host"].project == var.project_id,
      google_project_iam_member.repository_maintenance_iap["host"].member == "serviceAccount:infra-foundation@agora-management-test.iam.gserviceaccount.com",
      google_project_iam_member.repository_maintenance_iap["host"].role == "roles/iap.tunnelResourceAccessor",
      google_project_iam_member.repository_maintenance_iap["host"].condition[0].expression == "destination.port == 22 && destination.ip == '10.90.0.3'",
    ])
    error_message = "Protected maintenance may tunnel only to SSH on the prepared repository's private IP."
  }
}

run "activate_existing_shared_repository" {
  command = plan
  variables {
    database_handoff = run.documents.cases.json_keys
    pgbackrest_repository = {
      active    = true
      placement = run.documents.repository_placement
      runtime = merge(jsondecode(file("tests/fixtures/repository-runtime.json")), {
        server_image      = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-production/service-json-keys/database@sha256:${sha256("server")}"
        credentials_image = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-tooling/host-credentials@sha256:${sha256("credentials")}"
      })
    }
  }
  assert {
    condition = alltrue([
      google_compute_instance.repository["host"].desired_status == "RUNNING",
      yamldecode(local.repository_cloud_config.host).ssh_deletekeys == false,
      google_compute_instance.repository["host"].machine_type == "e2-micro",
      yamldecode(local.repository_cloud_config.host).runcmd == [
        ["systemctl", "daemon-reload"],
        ["ssh-keygen", "-lf", "/mnt/stateful_partition/etc/ssh/ssh_host_ed25519_key.pub", "-E", "sha256"],
        ["systemctl", "start", "agora-backup-repository.service"],
      ],
      strcontains(yamldecode(local.repository_cloud_config.host).write_files[2].content, "Restart=on-failure"),
      strcontains(yamldecode(local.repository_cloud_config.host).write_files[2].content, "SuccessExitStatus=63\nRestartForceExitStatus=63\n"),
      length(google_compute_instance_group_manager.database) == 0,
      length(google_compute_disk.database) == 0,
      output.native_bringup == null,
    ])
    error_message = "Explicit activation starts only the existing private repository and keeps database ownership in its original state."
  }
}

run "reject_activation_without_runtime" {
  command = plan
  variables {
    database_handoff      = run.documents.cases.json_keys
    pgbackrest_repository = { active = true, placement = run.documents.repository_placement }
  }
  expect_failures = [var.pgbackrest_repository]
}

run "reject_unscoped_runtime_images" {
  command = plan
  variables {
    database_handoff = run.documents.cases.json_keys
    pgbackrest_repository = {
      placement = run.documents.repository_placement
      runtime = merge(jsondecode(file("tests/fixtures/repository-runtime.json")), {
        server_image      = "europe-west1-docker.pkg.dev/agora-private-test/agora-production/service-json-keys/database@sha256:${sha256("server")}"
        credentials_image = "europe-west1-docker.pkg.dev/agora-private-test/agora-tooling/host-credentials@sha256:${sha256("credentials")}"
      })
    }
  }
  expect_failures = [var.pgbackrest_repository]
}

run "reject_larger_host" {
  command = plan
  variables {
    database_handoff      = run.documents.cases.json_keys
    pgbackrest_repository = { placement = run.documents.repository_placement, machine_type = "e2-small" }
  }
  expect_failures = [var.pgbackrest_repository]
}

run "reject_database_activation" {
  command = plan
  variables {
    database_handoff = run.documents.cases.json_keys
    database_runtime = merge(jsondecode(file("tests/fixtures/database-runtime.json")), { bring_up = true })
  }
  expect_failures = [var.database_runtime]
}

run "reject_peer_subnet" {
  command = plan
  variables {
    database_handoff = run.documents.cases.json_keys
    pgbackrest_repository = { placement = merge(run.documents.repository_placement, {
      subnetwork = "projects/agora-peer-test/regions/europe-west1/subnetworks/peer"
    }) }
  }
  expect_failures = [var.pgbackrest_repository]
}

run "reject_other_zone" {
  command = plan
  variables {
    database_handoff      = run.documents.cases.json_keys
    pgbackrest_repository = { placement = merge(run.documents.repository_placement, { zone = "europe-west1-d" }) }
  }
  expect_failures = [var.pgbackrest_repository]
}

run "reject_image_family" {
  command = plan
  variables {
    database_handoff      = run.documents.cases.json_keys
    pgbackrest_repository = { placement = merge(run.documents.repository_placement, { cos_image = "cos-stable" }) }
  }
  expect_failures = [var.pgbackrest_repository]
}
