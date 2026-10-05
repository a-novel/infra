mock_provider "google" {}

variables {
  recovery = jsondecode(file("tests/fixture.json"))
}

run "disabled" {
  command = plan
  variables { recovery = null }
  assert {
    condition     = length(google_compute_instance.recovery) == 0 && length(google_compute_disk.data) == 0 && length(google_compute_network.recovery) == 0
    error_message = "Default preparation must allocate no resources."
  }
}

run "selected_host" {
  command = plan
  assert {
    condition = alltrue([
      google_compute_instance.recovery["selected"].desired_status == "TERMINATED",
      google_compute_instance.recovery["selected"].scheduling[0].automatic_restart == false,
      google_compute_instance.recovery["selected"].scheduling[0].max_run_duration[0].seconds == 14400,
      google_compute_instance.recovery["selected"].scheduling[0].instance_termination_action == "STOP",
      length(google_compute_instance.recovery["selected"].network_interface[0].access_config) == 0,
      google_compute_instance.recovery["selected"].service_account[0].email == "pgbr-json-keys-recovery@management-project.iam.gserviceaccount.com",
      google_compute_network.recovery["selected"].delete_default_routes_on_create,
      google_compute_route.google_apis["selected"].dest_range == "199.36.153.4/30",
      google_compute_disk.data["selected"].size == 10,
    ])
    error_message = "Recovery must stay stopped, bounded and isolated with independent authority."
  }
  assert {
    condition = alltrue([
      jsonencode(yamldecode(google_compute_instance.recovery["selected"].metadata["user-data"]).runcmd) == jsonencode([["systemctl", "daemon-reload"]]),
      yamldecode(google_compute_instance.recovery["selected"].metadata["user-data"]).ssh_deletekeys == false,
      jsondecode(yamldecode(google_compute_instance.recovery["selected"].metadata["user-data"]).write_files[0].content) == local.requests["selected"],
      local.requests["selected"].repository_time == "2026-09-27T20:35:40Z",
      !local.requests["selected"].verify_sql,
      !strcontains(yamldecode(google_compute_instance.recovery["selected"].metadata["user-data"]).write_files[2].content, "[Install]"),
    ])
    error_message = "Boot may register the exact request and unit only; it must not execute restoration."
  }
}

run "offline_sql" {
  command = plan
  variables {
    recovery = merge(jsondecode(file("tests/fixture.json")), { verify_sql = true, expected_data_sha256 = sha256("source") })
  }
  assert {
    condition = alltrue([
      local.requests["selected"].verify_sql,
      local.requests["selected"].expected_data_sha256 == sha256("source"),
      strcontains(yamldecode(google_compute_instance.recovery["selected"].metadata["user-data"]).write_files[3].content, "--network=none"),
      strcontains(yamldecode(google_compute_instance.recovery["selected"].metadata["user-data"]).write_files[3].content, " verify-sql"),
      !strcontains(yamldecode(google_compute_instance.recovery["selected"].metadata["user-data"]).write_files[3].content, "docker pull"),
      !strcontains(yamldecode(google_compute_instance.recovery["selected"].metadata["user-data"]).write_files[3].content, "[Install]"),
    ])
    error_message = "SQL verification must be explicit, manual, networkless and reuse the previously pulled image."
  }
}

run "data_without_sql" {
  command = plan
  variables {
    recovery = merge(jsondecode(file("tests/fixture.json")), { expected_data_sha256 = sha256("source") })
  }
  expect_failures = [var.recovery]
}

run "malformed_data" {
  command = plan
  variables {
    recovery = merge(jsondecode(file("tests/fixture.json")), { verify_sql = true, expected_data_sha256 = "invalid" })
  }
  expect_failures = [var.recovery]
}

run "protected_target" {
  command = plan
  variables {
    recovery = merge(jsondecode(file("tests/fixture.json")), { protected_projects = ["source-project", "management-project", "a-novel-recovery-proof"] })
  }
  expect_failures = [var.recovery]
}

run "unqualified_image" {
  command = plan
  variables {
    recovery = merge(jsondecode(file("tests/fixture.json")), { restore_image = "ghcr.io/a-novel/infra/native-restore:latest" })
  }
  expect_failures = [var.recovery]
}

run "implicit_set" {
  command = plan
  variables {
    recovery = merge(jsondecode(file("tests/fixture.json")), { set = "latest" })
  }
  expect_failures = [var.recovery]
}
