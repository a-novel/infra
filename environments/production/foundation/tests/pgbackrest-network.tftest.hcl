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
}

run "default_network_is_unchanged" {
  command = plan

  assert {
    condition = alltrue([for rules in [
      google_compute_firewall.pgbackrest_database_egress, google_compute_firewall.pgbackrest_repository_ingress,
      google_compute_firewall.pgbackrest_google_egress, google_compute_firewall.pgbackrest_iap_ingress,
    ] : length(rules) == 0])
    error_message = "Default inputs must not create repository network rules."
  }
}

run "only_selected_database_reaches_its_repository" {
  command = plan

  variables {
    service_projects = {
      json-keys      = "agora-json-keys-test"
      authentication = "agora-authentication-test"
    }
    pgbackrest_repository_services = ["json-keys"]
  }

  assert {
    condition = alltrue([for rules in [
      google_compute_firewall.pgbackrest_database_egress, google_compute_firewall.pgbackrest_repository_ingress,
      google_compute_firewall.pgbackrest_google_egress, google_compute_firewall.pgbackrest_iap_ingress,
    ] : keys(rules) == ["json-keys"]])
    error_message = "Only the selected service gets repository rules, even with a peer project declared."
  }

  assert {
    condition = alltrue([for name, contract in {
      database_egress = {
        rule        = google_compute_firewall.pgbackrest_database_egress["json-keys"]
        direction   = "EGRESS"
        target      = "agora-database"
        source      = []
        ranges      = []
        destination = ["10.20.0.0/24"]
        port        = "8432"
      }
      repository_tls = {
        rule        = google_compute_firewall.pgbackrest_repository_ingress["json-keys"]
        direction   = "INGRESS"
        target      = "agora-backup-repository"
        source      = ["agora-database@agora-json-keys-test.iam.gserviceaccount.com"]
        ranges      = []
        destination = []
        port        = "8432"
      }
      repository_api = {
        rule        = google_compute_firewall.pgbackrest_google_egress["json-keys"]
        direction   = "EGRESS"
        target      = "agora-backup-repository"
        source      = []
        ranges      = []
        destination = ["199.36.153.4/30", "34.126.0.0/18"]
        port        = "443"
      }
      repository_shell = {
        rule        = google_compute_firewall.pgbackrest_iap_ingress["json-keys"]
        direction   = "INGRESS"
        target      = "agora-backup-repository"
        source      = []
        ranges      = ["35.235.240.0/20"]
        destination = []
        port        = "22"
      }
      } : alltrue([
        contract.rule.project == var.workload_project_id,
        contract.rule.network == google_compute_network.production.name,
        contract.rule.direction == contract.direction,
        contract.rule.priority < google_compute_firewall.deny_other_egress.priority,
        sort(contract.rule.target_service_accounts) == tolist(["${contract.target}@agora-json-keys-test.iam.gserviceaccount.com"]),
        sort(coalesce(contract.rule.source_service_accounts, [])) == sort(contract.source),
        sort(coalesce(contract.rule.source_ranges, [])) == sort(contract.ranges),
        sort(coalesce(contract.rule.destination_ranges, [])) == sort(contract.destination),
        contract.rule.source_tags == null, contract.rule.target_tags == null,
        length(contract.rule.deny) == 0,
        one(contract.rule.allow).protocol == "tcp",
        one(contract.rule.allow).ports == tolist([contract.port]),
    ])])
    error_message = "Each native rule must retain its exact identity, direction and protocol boundary, without alternate source tags/ranges."
  }
}

run "shared_private_network" {
  command = plan
  variables {
    shared_vpc_enabled             = true
    public_api_project_id          = "agora-api-test"
    public_project_id              = "agora-platform-test"
    service_release_zones          = { json-keys = ["private", "public-api"], authentication = ["private", "public-api"] }
    pgbackrest_repository_services = ["json-keys"]
  }
  assert {
    condition = alltrue([
      toset(keys(local.pgbackrest_network)) == toset(["json-keys"]),
      google_compute_firewall.pgbackrest_database_egress["json-keys"].target_service_accounts == toset(["agora-json-keys-database@agora-production-test.iam.gserviceaccount.com"]),
      google_compute_firewall.pgbackrest_repository_ingress["json-keys"].source_service_accounts == toset(["agora-json-keys-database@agora-production-test.iam.gserviceaccount.com"]),
      alltrue([for rule in [
        google_compute_firewall.pgbackrest_repository_ingress["json-keys"],
        google_compute_firewall.pgbackrest_google_egress["json-keys"],
        google_compute_firewall.pgbackrest_iap_ingress["json-keys"],
      ] : rule.target_service_accounts == toset(["agora-pgbr-json-keys@agora-production-test.iam.gserviceaccount.com"])]),
      google_compute_firewall.pgbackrest_repository_ingress["json-keys"].source_ranges == null,
      one(google_compute_firewall.pgbackrest_repository_ingress["json-keys"].allow).ports == tolist(["8432"]),
      length(google_compute_shared_vpc_service_project.service) == 0,
    ])
    error_message = "Only the selected private database may reach its repository; API identities and peer databases receive no rule."
  }
}

run "public_only_service_is_rejected" {
  command = plan
  variables {
    shared_vpc_enabled             = true
    public_api_project_id          = "agora-api-test"
    service_release_zones          = { json-keys = ["public-api"] }
    pgbackrest_repository_services = ["json-keys"]
  }
  expect_failures = [var.pgbackrest_repository_services]
}

run "missing_service_project_is_rejected" {
  command = plan
  variables {
    pgbackrest_repository_services = ["json-keys"]
  }
  expect_failures = [var.pgbackrest_repository_services]
}

run "peer_activation_is_rejected" {
  command = plan
  variables {
    service_projects               = { authentication = "agora-authentication-test" }
    pgbackrest_repository_services = ["authentication"]
  }
  expect_failures = [var.pgbackrest_repository_services]
}

run "recovery_ignores_copied_production_opt_in" {
  command = plan
  variables {
    recovery_mode                  = true
    workload_project_id            = "agora-recovery-test"
    pgbackrest_repository_services = ["json-keys"]
  }
  assert {
    condition = alltrue([for rules in [
      google_compute_firewall.pgbackrest_database_egress, google_compute_firewall.pgbackrest_repository_ingress,
      google_compute_firewall.pgbackrest_google_egress, google_compute_firewall.pgbackrest_iap_ingress,
    ] : length(rules) == 0])
    error_message = "Copied production options must not add repository connectivity to a recovery project."
  }
}
