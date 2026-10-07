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
      length(google_artifact_registry_repository_iam_member.repository_images) == 0,
      length(google_logging_metric.database_backup_success) == 0,
      length(google_monitoring_alert_policy.database_backup_health) == 0,
      length(google_monitoring_alert_policy.database_backup_failure) == 0,
      output.pgbackrest_repository == null,
      output.native_bringup == null,
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
      !contains(keys(google_compute_instance.repository["host"].metadata), "user-data"),
      length(google_artifact_registry_repository_iam_member.repository_images) == 0,
      alltrue([for binding in google_secret_manager_secret_iam_member.database : binding.member != "serviceAccount:${google_service_account.repository["host"].email}"]),
      output.pgbackrest_repository.service_account == google_service_account.repository["host"].email,
    ])
    error_message = "Foundation attaches the exact repository identity; it receives no database secret or readiness payload."
  }
}

run "prepared_runtime_stays_inactive" {
  command = plan
  variables {
    pgbackrest_repository = { runtime = jsondecode(file("tests/fixtures/repository-runtime.json")) }
  }

  assert {
    condition = alltrue([
      google_compute_instance.repository["host"].desired_status == "TERMINATED",
      yamldecode(local.repository_cloud_config.host).ssh_deletekeys == false,
      yamldecode(local.repository_cloud_config.host).runcmd == [["systemctl", "daemon-reload"]],
      google_compute_instance.repository["host"].metadata["user-data"] == local.repository_cloud_config.host,
      length(yamldecode(local.repository_cloud_config.host).write_files) == 3,
    ])
    error_message = "A prepared runtime must only install public files and register a disabled unit on boot."
  }

  assert {
    condition = alltrue([for binding in google_artifact_registry_repository_iam_member.repository_images :
      binding.project == var.project_id && binding.role == "roles/artifactregistry.reader" &&
      binding.member == "serviceAccount:${google_service_account.repository["host"].email}"
      ]) && toset(keys(google_artifact_registry_repository_iam_member.repository_images)) == toset([
      "agora-production", "agora-tooling",
    ])
    error_message = "Only this project's two image repositories grant the dedicated host reader access."
  }

  assert {
    condition = alltrue([for option in [
      "repo1-gcs-bucket=agora-management-test-123456789012-pgbr-json-keys",
      "tls-server-auth=agora-database.agora-json-keys-test=json-keys",
      "tls-server-key-file=/run/credentials/identity.pem",
    ] : strcontains(yamldecode(local.repository_cloud_config.host).write_files[1].content, option)])
    error_message = "Native configuration must bind the selected management bucket and service client."
  }

  assert {
    condition = alltrue([for option in [
      "RuntimeDirectoryPreserve=no", "Restart=no", "SuccessExitStatus=63\n", "RestartForceExitStatus=\n", "ExecStopPost=",
      "--management-project-number=123456789012", "--workload-project=agora-json-keys-test",
      "--endpoint=repository --ca-version=1 --identity-version=2",
      "--name=agora-pgbackrest-json-keys.europe-west1-b.c.agora-json-keys-test.internal",
      "--output=/credentials/current", "target=/run/credentials,readonly",
      "ExecStartPre=/sbin/iptables -w 5 -I INPUT 1 -p tcp --dport 8432 -m comment --comment agora-backup-repository -j ACCEPT",
      "ExecStopPost=-/sbin/iptables -w 5 -D INPUT -p tcp --dport 8432 -m comment --comment agora-backup-repository -j ACCEPT",
    ] : strcontains(yamldecode(local.repository_cloud_config.host).write_files[2].content, option)])
    error_message = "The service must use exact credential versions, private ephemeral delivery and stopped-consumer cleanup."
  }
}

run "reject_peer_server_image" {
  command = plan
  variables {
    pgbackrest_repository = { runtime = merge(jsondecode(file("tests/fixtures/repository-runtime.json")), {
      server_image = "europe-west1-docker.pkg.dev/agora-peer-test/agora-production/service-json-keys/database@sha256:${sha256("server")}"
    }) }
  }
  expect_failures = [var.pgbackrest_repository]
}

run "prepared_database_lifecycle" {
  command = plan
  variables {
    pgbackrest_repository = { runtime = jsondecode(file("tests/fixtures/repository-runtime.json")) }
    database_runtime      = jsondecode(file("tests/fixtures/database-runtime.json"))
  }
  override_resource {
    target = google_compute_instance.repository
    values = { network_interface = { network_ip = "10.90.0.3" } }
  }
  assert {
    condition = alltrue([
      output.native_bringup == null,
      google_compute_instance_group_manager.database["host"].update_policy[0].type == "OPPORTUNISTIC",
      google_compute_instance_template.database["host"].metadata_startup_script == null,
      !contains(keys(google_compute_instance_template.database["host"].metadata), "shutdown-script"),
      google_compute_instance_template.database["host"].metadata["user-data"] == local.database_cloud_config.host,
      yamldecode(local.database_cloud_config.host).runcmd == [["systemctl", "daemon-reload"]],
      yamldecode(local.database_cloud_config.host).ssh_deletekeys == false,
      length(yamldecode(local.database_cloud_config.host).write_files) == 13,
      google_compute_instance_group_manager.database["host"].all_instances_config[0].metadata == tomap({
        agora-json-keys-database-image            = var.pgbackrest_repository.runtime.server_image
        agora-json-keys-postgres-password-version = "3"
        agora-database-release-revision           = var.database_runtime.revision
      }),
      google_artifact_registry_repository_iam_member.database_tooling["host"].repository == "agora-tooling",
      google_artifact_registry_repository_iam_member.database_tooling["host"].role == "roles/artifactregistry.reader",
      google_artifact_registry_repository_iam_member.database_tooling["host"].member == "serviceAccount:${google_service_account.database["host"].email}",
    ])
    error_message = "Preparation must replace legacy boot ownership without starting PostgreSQL or publishing secrets."
  }
  assert {
    condition = alltrue([for option in [
      "Type=notify", "Restart=on-failure", "StartLimitBurst=3", "RuntimeDirectoryPreserve=no",
      "PGBACKREST_REPOSITORY_IP=10.90.0.3", "--endpoint=database --ca-version=1 --identity-version=5",
      "--name=agora-database.agora-json-keys-test", "--supervise", "ExecStopPost=",
      "Environment=PGBACKREST_WAL_ARCHIVING=false", "/run/agora/postgresql /run/agora/pgbackrest-lock",
      "kill agora-backup-check agora-backup-diff agora-backup-full agora-backup-stanza-create agora-backup-verify",
    ] : strcontains(yamldecode(local.database_cloud_config.host).write_files[3].content, option)])
    error_message = "Systemd must own bounded restart, exact TLS delivery and stopped-consumer cleanup."
  }
  assert {
    condition = alltrue([for option in [
      "repo1-host=${local.repository_name}", "repo1-host-type=tls", "repo1-host-port=8432",
      "repo1-host-key-file=/run/pgbackrest/identity.pem", "expire-auto=y",
      "repo1-retention-full-type=time", "repo1-retention-full=14",
      "pg1-path=/var/lib/postgresql/18/docker", "pg1-user=agora_json_keys",
      "pg1-socket-path=/var/run/postgresql", "lock-path=/run/pgbackrest-lock", "process-max=1",
    ] : strcontains(yamldecode(local.database_cloud_config.host).write_files[2].content, option)])
    error_message = "The client must use native TLS and the selected PostgreSQL 18 layout, without GCS credentials."
  }
  assert {
    condition = alltrue(flatten([for file in slice(yamldecode(local.database_cloud_config.host).write_files, 4, 9) : [
      for option in [
        "Type=exec", "Restart=no", "RuntimeMaxSec=1h", "TimeoutStopSec=45",
        "StopPropagatedFrom=agora-database.service docker.service",
        "ExecStartPre=/usr/bin/systemctl is-active --quiet agora-database.service",
        "--network=container:agora-postgres-json-keys", "--read-only --user=999:999",
        "--cpus=0.5 --memory=512m --memory-swap=512m", "--pids-limit=64",
        "source=/mnt/disks/agora-data/json-keys,target=/var/lib/postgresql,readonly",
        "source=/run/agora/postgresql,target=/var/run/postgresql,readonly",
        "source=/run/agora/pgbackrest-lock,target=/run/pgbackrest-lock",
        var.pgbackrest_repository.runtime.server_image,
        "ExecStop=-/usr/bin/docker stop", "ExecStopPost=-/usr/bin/docker kill",
        "--log-driver=json-file --log-opt=max-size=2m --log-opt=max-file=2 --log-opt=tag={{.Name}}",
      ] : strcontains(file.content, option)
    ]]))
    error_message = "Native jobs must reuse the database's image, socket, locks and isolated network with bounded container cleanup."
  }
  assert {
    condition = alltrue([for name, command in {
      stanza-create = "stanza-create"
      check         = "check"
      full          = "--type=full --archive-copy --repo1-bundle backup"
      diff          = "--type=diff --archive-copy --repo1-bundle backup"
      verify        = "--output=text --verbose --log-level-console=error verify"
      } : strcontains(one([for file in yamldecode(local.database_cloud_config.host).write_files : file.content
      if file.path == "/etc/systemd/system/agora-backup-${name}.service"]), "--stanza=json-keys ${command}\n")
    ])
    error_message = "Each worker must use its native options; verification must emit a text report even when it exits zero."
  }
  assert {
    condition = alltrue([for name in ["check", "full", "diff", "verify", "stanza-create"] :
      strcontains(one([for file in yamldecode(local.database_cloud_config.host).write_files : file.content
      if file.path == "/etc/systemd/system/agora-backup-${name}.service"]), "/etc/pgbackrest/check-backup.sh") == (name == "check")
      ]) && one([for file in yamldecode(local.database_cloud_config.host).write_files : file.content
      if file.path == "/etc/agora-database/check-backup.sh"
    ]) == file("../../assets/database-host/check-backup.sh")
    error_message = "Only the hourly check must forecast TLS expiry; backups and archive workers keep their native entrypoint."
  }
  assert {
    condition = alltrue([for file in yamldecode(local.database_cloud_config.host).write_files :
      !strcontains(file.content, "[Install]")
    ])
    error_message = "Prepared jobs and timers must not enable boot activation."
  }
  assert {
    condition = alltrue([for name, calendar in {
      full = "Sun *-*-* 02:00:00 UTC", diff = "Mon..Sat *-*-* 02:00:00 UTC", check = "*-*-* *:30:00 UTC",
      } : alltrue([for option in [
        "OnCalendar=${calendar}", "Unit=agora-backup-${name}.service", "Persistent=false",
        "RandomizedDelaySec=5m", "PartOf=agora-database.service",
        ] : strcontains(one([for file in yamldecode(local.database_cloud_config.host).write_files : file.content
      if file.path == "/etc/systemd/system/agora-backup-${name}.timer"]), option)])
    ])
    error_message = "Only full, differential and checks get UTC timers; they follow database restarts without replaying missed jobs."
  }
  assert {
    condition = alltrue([
      !google_monitoring_alert_policy.database_backup_failure["host"].enabled,
      google_monitoring_alert_policy.database_backup_failure["host"].notification_channels == tolist([google_monitoring_notification_channel.operations.name]),
      toset(keys(google_monitoring_alert_policy.database_backup_health)) == toset(["full", "backup", "check", "disk"]),
      google_logging_metric.database_backup_success["host"].project == var.project_id,
      google_logging_metric.database_backup_success["host"].label_extractors == tomap({ job = "EXTRACT(jsonPayload.\"cos.googleapis.com/container_name\")" }),
    ])
    error_message = "Monitoring must remain disabled in the selected project and use the existing notification channel."
  }
  assert {
    condition = alltrue([for message, matched in {
      "stanza: json-keys\nstatus: error\n  backup: invalid\n" = true
      "    no archives or backups exist in the repo\n"        = true
      "stanza: json-keys\nstatus: ok\n"                       = false
      "verify command end: completed successfully"            = false
    } : can(regex(local.database_verify_failure_pattern, message)) == matched])
    error_message = "Integrity alerts must distinguish native damage and empty-repository reports from healthy or completed commands."
  }
  assert {
    condition = alltrue([for policy in google_monitoring_alert_policy.database_backup_health :
      alltrue([
        !policy.enabled, length(policy.conditions) == 1, policy.project == var.project_id,
        policy.notification_channels == tolist([google_monitoring_notification_channel.operations.name]),
        policy.conditions[0].condition_prometheus_query_language[0].duration == "600s",
      ])
    ])
    error_message = "Each disabled health policy must have one native condition and the service's notification channel."
  }
}

run "backup_alerts_do_not_activate_hosts" {
  command = plan
  variables {
    pgbackrest_repository = { runtime = jsondecode(file("tests/fixtures/repository-runtime.json")) }
    database_runtime      = merge(jsondecode(file("tests/fixtures/database-runtime.json")), { backup_alerts_enabled = true })
  }
  assert {
    condition = alltrue(concat(
      [google_monitoring_alert_policy.database_backup_failure["host"].enabled],
      [for policy in google_monitoring_alert_policy.database_backup_health : policy.enabled],
    ))
    error_message = "Explicit approval enables the five existing native alert policies."
  }
  assert {
    condition = alltrue([
      output.native_bringup == null,
      !var.database_runtime.wal_archiving,
      google_compute_instance.repository["host"].desired_status == "TERMINATED",
      google_compute_instance_group_manager.database["host"].update_policy[0].type == "OPPORTUNISTIC",
      yamldecode(local.database_cloud_config.host).runcmd == [["systemctl", "daemon-reload"]],
      yamldecode(local.repository_cloud_config.host).runcmd == [["systemctl", "daemon-reload"]],
    ])
    error_message = "Alert activation must leave host bring-up, WAL and timers inactive."
  }
}

run "guarded_bringup_uses_native_reconciliation" {
  command = plan
  variables {
    pgbackrest_repository = { runtime = jsondecode(file("tests/fixtures/repository-runtime.json")) }
    database_runtime      = merge(jsondecode(file("tests/fixtures/database-runtime.json")), { bring_up = true })
  }
  override_resource {
    target = google_compute_instance.repository
    values = { network_interface = { network_ip = "10.90.0.3" } }
  }
  assert {
    condition = [
      google_compute_instance.repository["host"].desired_status,
      google_compute_instance_group_manager.database["host"].update_policy[0].type,
      google_compute_instance_group_manager.database["host"].update_policy[0].replacement_method,
      tostring(google_compute_instance_group_manager.database["host"].update_policy[0].max_surge_fixed),
    ] == ["RUNNING", "PROACTIVE", "RECREATE", "0"]
    error_message = "Explicit bring-up delegates singleton reconciliation to Google without a second database writer."
  }
  assert {
    condition = alltrue([
      output.native_bringup.project == var.project_id,
      output.native_bringup.group == "agora-database-json-keys",
      output.native_bringup.image == var.pgbackrest_repository.runtime.server_image,
      output.native_bringup.database.metadata["user-data"] == local.database_cloud_config.host,
      output.native_bringup.repository.metadata["user-data"] == local.repository_cloud_config.host,
      yamldecode(local.database_cloud_config.host).runcmd == [["systemctl", "daemon-reload"]],
      yamldecode(local.repository_cloud_config.host).runcmd == [["systemctl", "daemon-reload"]],
    ])
    error_message = "Private targets must bind expected configuration; boot still starts no services or timers."
  }
}

run "explicit_wal_archiving" {
  command = plan
  variables {
    pgbackrest_repository = { runtime = jsondecode(file("tests/fixtures/repository-runtime.json")) }
    database_runtime      = merge(jsondecode(file("tests/fixtures/database-runtime.json")), { wal_archiving = true })
  }
  override_resource {
    target = google_compute_instance.repository
    values = { network_interface = { network_ip = "10.90.0.3" } }
  }
  assert {
    condition     = strcontains(yamldecode(local.database_cloud_config.host).write_files[3].content, "Environment=PGBACKREST_WAL_ARCHIVING=true")
    error_message = "WAL archiving requires an explicit foundation-owned opt-in."
  }
}

run "reject_database_without_repository_runtime" {
  command = plan
  variables { database_runtime = jsondecode(file("tests/fixtures/database-runtime.json")) }
  expect_failures = [var.database_runtime]
}

run "reject_database_password_alias" {
  command = plan
  variables {
    pgbackrest_repository = { runtime = jsondecode(file("tests/fixtures/repository-runtime.json")) }
    database_runtime      = merge(jsondecode(file("tests/fixtures/database-runtime.json")), { password_version = "latest" })
  }
  expect_failures = [var.database_runtime]
}

run "reject_database_identity_injection" {
  command = plan
  variables {
    pgbackrest_repository = { runtime = jsondecode(file("tests/fixtures/repository-runtime.json")) }
    database_runtime      = merge(jsondecode(file("tests/fixtures/database-runtime.json")), { identity_version = "5\nExecStart=/bin/true" })
  }
  expect_failures = [var.database_runtime]
}

run "reject_database_revision" {
  command = plan
  variables {
    pgbackrest_repository = { runtime = jsondecode(file("tests/fixtures/repository-runtime.json")) }
    database_runtime      = merge(jsondecode(file("tests/fixtures/database-runtime.json")), { revision = "master" })
  }
  expect_failures = [var.database_runtime]
}

run "reject_unresolved_loader_image" {
  command = plan
  variables {
    pgbackrest_repository = { runtime = merge(jsondecode(file("tests/fixtures/repository-runtime.json")), {
      credentials_image = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-tooling/host-credentials:v1.0.0"
    }) }
  }
  expect_failures = [var.pgbackrest_repository]
}

run "reject_secret_alias" {
  command = plan
  variables {
    pgbackrest_repository = { runtime = merge(jsondecode(file("tests/fixtures/repository-runtime.json")), { ca_version = "latest" }) }
  }
  expect_failures = [var.pgbackrest_repository]
}

run "reject_identity_argument_injection" {
  command = plan
  variables {
    pgbackrest_repository = { runtime = merge(jsondecode(file("tests/fixtures/repository-runtime.json")), { identity_version = "2\nExecStart=/usr/bin/true" }) }
  }
  expect_failures = [var.pgbackrest_repository]
}

run "reject_missing_database" {
  command = plan
  variables {
    database              = null
    pgbackrest_repository = {}
  }
  expect_failures = [var.pgbackrest_repository]
}

run "authentication_has_a_separate_repository" {
  command = plan
  variables {
    service               = "authentication"
    pgbackrest_repository = {}
  }
  assert {
    condition = alltrue([
      google_compute_instance.repository["host"].name == "agora-pgbackrest-authentication",
      google_compute_instance.repository["host"].desired_status == "TERMINATED",
      google_compute_instance.repository["host"].machine_type == "e2-micro",
    ])
    error_message = "The shared implementation must prepare Authentication's separate bounded repository."
  }
}

run "reject_unbounded_profile" {
  command = plan
  variables { pgbackrest_repository = { machine_type = "e2-standard-8" } }
  expect_failures = [var.pgbackrest_repository]
}
