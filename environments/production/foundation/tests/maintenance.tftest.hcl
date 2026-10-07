mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email = "runtime-mock@agora-production-test.iam.gserviceaccount.com"
      name  = "projects/agora-production-test/serviceAccounts/runtime-mock@agora-production-test.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_tags_tag_key" {
    defaults = { id = "tagKeys/100000000001" }
  }
  mock_resource "google_tags_tag_value" {
    defaults = { id = "tagValues/200000000001" }
  }
  mock_data "google_billing_account" {
    defaults = { currency_code = "EUR" }
  }
}

mock_provider "google-beta" {
  mock_resource "google_project_service_identity" {
    defaults = { member = "serviceAccount:service-111111111111@serverless-robot-prod.iam.gserviceaccount.com" }
  }
}

variables {
  management_project_id  = "agora-management-test"
  workload_project_id    = "agora-production-test"
  adopt_default_network  = false
  backup_bucket_name     = "agora-management-test-123456789012-backups"
  billing_account_id     = "ABCDEF-123456-ABCDEF"
  cost_alert_email       = "infra@example.com"
  operations_alert_email = "operations@example.com"
  organization_id        = "123456789012"
  database_operator_principals = [
    "group:infra-operators@example.com",
  ]
  authentication_initializer_principals = [
    "group:authentication-initializers@example.com",
  ]
}

run "database_release_ownership" {
  command = plan
  variables {
    database_releases = {
      for service in ["json-keys", "authentication"] : service => {
        image                   = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-${service}/database@sha256:${join("", [for i in range(64) : "a"])}"
        revision                = join("", [for i in range(40) : "b"])
        password_version        = "2"
        backup_password_version = "3"
      }
    }
  }

  assert {
    condition = alltrue([for key, group in google_compute_instance_group_manager.database :
      one(group.all_instances_config).metadata == tomap({
        "agora-${replace(key, "_", "-")}-database-image"                   = var.database_releases[replace(key, "_", "-")].image
        "agora-${replace(key, "_", "-")}-postgres-password-version"        = "2"
        "agora-${replace(key, "_", "-")}-postgres-backup-password-version" = "3"
        "agora-database-release-revision"                                  = join("", [for i in range(40) : "b"])
      }) && one(group.update_policy).type == "OPPORTUNISTIC" && group.target_size == 1
    ])
    error_message = "Foundation must own exact release metadata without automatically updating members or adding capacity."
  }
}

run "reject_partial_database_releases" {
  command = plan
  variables {
    database_releases = {
      authentication = {
        image                   = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/database@sha256:${join("", [for i in range(64) : "a"])}"
        revision                = join("", [for i in range(40) : "b"])
        password_version        = "2"
        backup_password_version = "3"
      }
    }
  }
  expect_failures = [var.database_releases]
}

run "reject_foreign_database_release" {
  command = plan
  variables {
    database_releases = {
      for service in ["json-keys", "authentication"] : service => {
        image                   = "europe-west1-docker.pkg.dev/untrusted-project/agora-production/service-${service}/database@sha256:${join("", [for i in range(64) : "a"])}"
        revision                = join("", [for i in range(40) : "b"])
        password_version        = "2"
        backup_password_version = "3"
      }
    }
  }
  expect_failures = [var.database_releases]
}
