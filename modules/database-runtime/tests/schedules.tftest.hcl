variables {
  service           = "json-keys"
  project_id        = "agora-production-test"
  region            = "europe-west1"
  management_number = "123456789012"
  identity_version  = "1"
  repository = {
    name              = "repository.test"
    ip                = "10.20.0.7"
    server_image      = "database@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    credentials_image = "credentials@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    ca_version        = "1"
    client_name       = "database.test"
  }
}

run "prepared_schedules_stay_inactive" {
  command = plan
  assert {
    condition = !strcontains(one([for file in yamldecode(output.cloud_config).write_files : file.content
      if file.path == "/etc/systemd/system/agora-database.service"
    ]), "Wants=agora-backup-")
    error_message = "Enrollment alone must not start schedules."
  }
}

run "accepted_schedules_follow_database" {
  command = plan
  variables {
    wal_archiving     = true
    schedules_enabled = true
  }
  assert {
    condition = strcontains(one([for file in yamldecode(output.cloud_config).write_files : file.content
      if file.path == "/etc/systemd/system/agora-database.service"
    ]), "Wants=agora-backup-check.timer agora-backup-diff.timer agora-backup-full.timer")
    error_message = "Every healthy database start must activate the accepted schedules."
  }
  assert {
    condition = alltrue([for file in yamldecode(output.cloud_config).write_files : alltrue([
      strcontains(file.content, "After=agora-database.service"),
      strcontains(file.content, "Requisite=agora-database.service"),
      strcontains(file.content, "PartOf=agora-database.service"),
      strcontains(file.content, "Persistent=false"),
      !strcontains(file.content, "Upholds="),
    ]) if endswith(file.path, ".timer")])
    error_message = "Timers require a healthy database, follow its stop/restart and permit an explicit maintenance pause without catch-up."
  }
  assert {
    condition = alltrue([for file in yamldecode(output.cloud_config).write_files :
      !strcontains(file.content, "PartOf=") && !strcontains(file.content, "Restart=on-failure")
      if startswith(file.path, "/etc/systemd/system/agora-backup-") && endswith(file.path, ".service")
    ])
    error_message = "Restart propagation must never replay a backup worker."
  }
  assert {
    condition = alltrue([for option in ["repo1-retention-full-type=time", "repo1-retention-full=14", "expire-auto=y"] :
      strcontains(one([for file in yamldecode(output.cloud_config).write_files : file.content
      if file.path == "/etc/agora-database/pgbackrest.conf"]), option)
      ]) && alltrue([for file in yamldecode(output.cloud_config).write_files :
      !strcontains(file.content, "repo1-retention-diff=") && !strcontains(file.content, "repo1-retention-archive=") && !strcontains(file.content, "--no-expire-auto")
    ])
    error_message = "Native time-based expiry must preserve the fourteen-day full chain and all dependent differential backups and WAL."
  }
}

run "authentication_uses_same_schedules" {
  command = plan
  variables {
    service           = "authentication"
    wal_archiving     = true
    schedules_enabled = true
  }
  assert {
    condition = alltrue([for file in yamldecode(output.cloud_config).write_files :
      strcontains(file.content, "Description=Agora authentication native backup schedule") && !strcontains(file.content, "JSON Keys")
      if endswith(file.path, ".timer")
    ])
    error_message = "Authentication schedules must identify their own service."
  }
}

run "schedules_require_archiving" {
  command = plan
  variables {
    schedules_enabled = true
  }
  expect_failures = [var.schedules_enabled]
}
