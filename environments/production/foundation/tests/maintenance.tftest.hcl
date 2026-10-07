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

run "maintenance_permissions" {
  command = plan

  variables {
    legacy_backup_job_access = true
  }

  override_resource {
    target = google_tags_tag_key.legacy_backup[0]
    values = { id = "tagKeys/300000000001" }
  }

  override_resource {
    target = google_tags_tag_value.legacy_backup[0]
    values = { id = "tagValues/400000000001", name = "400000000001" }
  }

  assert {
    condition = (
      google_project_iam_custom_role.foundation_backup_jobs[0].permissions == toset(["run.jobs.run"]) &&
      google_project_iam_member.foundation_backup_jobs[0].member == "serviceAccount:infra-foundation@agora-management-test.iam.gserviceaccount.com" &&
      one(google_project_iam_member.foundation_backup_jobs[0].condition).expression == "resource.matchTagId('tagKeys/300000000001', 'tagValues/400000000001')"
    )
    error_message = "Maintenance must use the separate backup tag, without overrides, cancellation or deployments."
  }

  assert {
    condition = (
      toset(keys(google_tags_location_tag_binding.legacy_backup)) == toset([
        "agora-postgres-backup-json-keys", "agora-postgres-restore-json-keys",
        "agora-postgres-backup-authentication", "agora-postgres-restore-authentication",
        "agora-postgres-backup-monitor",
        ]) && alltrue([
        for job, binding in google_tags_location_tag_binding.legacy_backup :
        binding.parent == "//run.googleapis.com/projects/agora-production-test/locations/europe-west1/jobs/${job}" &&
        binding.location == "europe-west1" && binding.tag_value == "tagValues/400000000001"
      ]) && google_tags_tag_key.legacy_backup[0].short_name == "agora-backup-maintenance"
    )
    error_message = "Only the five existing backup jobs may receive the additive maintenance tag; key rotation and application jobs are excluded."
  }

  assert {
    condition = (
      google_project_iam_custom_role.foundation_backup_tagging[0].permissions == toset(["run.jobs.createTagBinding", "run.jobs.deleteTagBinding", "run.jobs.listTagBindings"]) &&
      one(google_project_iam_member.foundation_backup_tagging[0].condition).expression == "resource.matchTagId('tagKeys/100000000001', 'tagValues/200000000001')" &&
      google_tags_tag_value_iam_member.foundation_backup_tag[0].tag_value == "400000000001" &&
      google_tags_tag_value_iam_member.foundation_backup_tag[0].member == google_project_iam_member.foundation_backup_jobs[0].member &&
      one(google_project_iam_member.scheduler_cloud_run_invoker[0].condition).expression == "resource.matchTagId('tagKeys/100000000001', 'tagValues/200000000001')" &&
      strcontains(one(google_project_iam_member.release_cloud_run_invoker[0].condition).expression, "resource.matchTagId('tagKeys/100000000001', 'tagValues/200000000001')")
    )
    error_message = "Tag administration must not grant execution or change existing scheduler/release invocation authority."
  }

  assert {
    condition = (
      google_project_iam_custom_role.foundation_backup_observation[0].permissions == toset(["run.jobs.get", "run.executions.get", "run.operations.get"]) &&
      google_project_iam_member.foundation_backup_observation[0].member == google_project_iam_member.foundation_backup_jobs[0].member &&
      length(google_project_iam_member.foundation_backup_observation[0].condition) == 0
    )
    error_message = "Project-scoped polling must be metadata-read-only."
  }
}

run "default_off" {
  command = plan
  assert {
    condition = (
      length(google_tags_tag_key.legacy_backup) == 0 &&
      length(google_tags_tag_value.legacy_backup) == 0 &&
      length(google_tags_location_tag_binding.legacy_backup) == 0 &&
      length(google_project_iam_member.foundation_backup_jobs) == 0 &&
      length(google_project_iam_member.foundation_backup_observation) == 0 &&
      length(google_project_iam_member.foundation_backup_tagging) == 0 &&
      length(google_tags_tag_value_iam_member.foundation_backup_tag) == 0
    )
    error_message = "Cold foundations must not require existing backup jobs or grant maintenance access."
  }
}

run "no_recovery_grants" {
  command = plan
  variables {
    recovery_mode            = true
    legacy_backup_job_access = true
  }

  assert {
    condition = (
      length(google_project_iam_custom_role.foundation_backup_jobs) == 0 &&
      length(google_project_iam_member.foundation_backup_jobs) == 0 &&
      length(google_project_iam_custom_role.foundation_backup_observation) == 0 &&
      length(google_project_iam_member.foundation_backup_observation) == 0 &&
      length(google_tags_location_tag_binding.legacy_backup) == 0 &&
      length(google_tags_tag_key.legacy_backup) == 0 &&
      length(google_project_iam_member.foundation_backup_tagging) == 0
    )
    error_message = "Legacy maintenance grants do not belong in disposable recovery roots."
  }
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
