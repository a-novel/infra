mock_provider "google" {}

variables {
  management_project_id = "agora-management-test"
  workload_project_id   = "agora-production-test"
  backup_bucket_name    = "agora-management-test-123456789012-backups"
  database_private_ip   = "10.20.0.5"
  network_id            = "projects/agora-production-test/global/networks/agora-production"
  subnet_id             = "projects/agora-production-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
  runtime_service_accounts = {
    backup            = "agora-backup@agora-production-test.iam.gserviceaccount.com"
    restore           = "agora-restore@agora-production-test.iam.gserviceaccount.com"
    scheduler_invoker = "agora-scheduler-invoker@agora-production-test.iam.gserviceaccount.com"
  }
}

run "keeps_recovery_disabled_before_the_database_release" {
  command = plan

  assert {
    condition     = output.root_name == "release"
    error_message = "The release root identifier changed."
  }

  assert {
    condition     = output.region == "europe-west1"
    error_message = "The production region default changed."
  }

  assert {
    condition = (
      length(google_cloud_run_v2_job.postgres_backup) == 0 &&
      length(google_cloud_run_v2_job.postgres_restore) == 0 &&
      length(google_cloud_run_v2_job.postgres_backup_monitor) == 0 &&
      length(google_cloud_scheduler_job.postgres_backup) == 0 &&
      length(google_cloud_scheduler_job.postgres_restore) == 0 &&
      length(google_cloud_scheduler_job.postgres_backup_monitor) == 0
    )
    error_message = "No recovery job or schedule may exist before both database releases are enabled."
  }
}

run "builds_the_two_database_recovery_contracts" {
  command = plan

  variables {
    database_releases = {
      authentication = {
        image                   = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/database@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        backup_password_version = 11
      }
      json_keys = {
        image                   = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/database@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        backup_password_version = 7
      }
    }
  }

  assert {
    condition = (
      length(google_cloud_run_v2_job.postgres_backup) == 2 &&
      length(google_cloud_run_v2_job.postgres_restore) == 2 &&
      length(google_cloud_run_v2_job.postgres_backup_monitor) == 1 &&
      length(google_cloud_scheduler_job.postgres_backup) == 2 &&
      length(google_cloud_scheduler_job.postgres_restore) == 2 &&
      length(google_cloud_scheduler_job.postgres_backup_monitor) == 1
    )
    error_message = "Recovery must stay at two backup jobs, two restore jobs, and one shared monitor."
  }

  assert {
    condition = alltrue([
      for job in values(google_cloud_run_v2_job.postgres_backup) :
      !job.deletion_protection &&
      one(job.template).task_count == 1 &&
      one(job.template).parallelism == 1 &&
      one(one(job.template).template).service_account == var.runtime_service_accounts.backup &&
      one(one(job.template).template).max_retries == 1 &&
      one(one(job.template).template).timeout == "1800s" &&
      one(one(job.template).template).execution_environment == "EXECUTION_ENVIRONMENT_GEN2" &&
      one(one(one(job.template).template).vpc_access).egress == "ALL_TRAFFIC" &&
      toset(one(one(one(job.template).template).vpc_access).network_interfaces[0].tags) == toset(["agora-backup"])
    ])
    error_message = "Backup jobs lost their singleton, retry, timeout, identity, or deny-by-default VPC contract."
  }

  assert {
    condition = alltrue([
      for job in values(google_cloud_run_v2_job.postgres_backup) :
      length(one(one(job.template).template).containers) == 2 &&
      toset(one([
        for container in one(one(job.template).template).containers : container
        if container.name == "backup"
      ]).command) == toset(["/bin/bash", "-c"]) &&
      one([
        for container in one(one(job.template).template).containers : container
        if container.name == "upload"
      ]).image == var.backup_uploader_image &&
      toset(one([
        for container in one(one(job.template).template).containers : container
        if container.name == "upload"
      ]).command) == toset(["/bin/su"]) &&
      one([
        for container in one(one(job.template).template).containers : container
        if container.name == "upload"
      ]).args[0] == "-s" &&
      one([
        for container in one(one(job.template).template).containers : container
        if container.name == "upload"
      ]).args[1] == "/bin/sh" &&
      one([
        for container in one(one(job.template).template).containers : container
        if container.name == "upload"
      ]).args[2] == "nobody" &&
      one([
        for container in one(one(job.template).template).containers : container
        if container.name == "upload"
      ]).args[3] == "-c" &&
      strcontains(one([
        for container in one(one(job.template).template).containers : container
        if container.name == "backup"
      ]).args[0], "pg_dump") &&
      strcontains(one([
        for container in one(one(job.template).template).containers : container
        if container.name == "backup"
      ]).args[0], "current_setting('agora.database_image', true)") &&
      strcontains(one([
        for container in one(one(job.template).template).containers : container
        if container.name == "backup"
      ]).args[0], "install -d -m 0733") &&
      strcontains(one([
        for container in one(one(job.template).template).containers : container
        if container.name == "backup"
      ]).args[0], "chmod 0755") &&
      strcontains(one([
        for container in one(one(job.template).template).containers : container
        if container.name == "backup"
      ]).args[0], "SELECT count(*) FROM pg_auth_members") &&
      one([
        for environment in one([
          for container in one(one(job.template).template).containers : container
          if container.name == "backup"
        ]).env : environment.value
        if environment.name == "EXPECTED_EXTENSIONS"
      ]) == "plpgsql,uuid-ossp" &&
      strcontains(one([
        for container in one(one(job.template).template).containers : container
        if container.name == "upload"
      ]).args[4], "ifGenerationMatch=0") &&
      strcontains(one([
        for container in one(one(job.template).template).containers : container
        if container.name == "upload"
      ]).args[4], "$${WORKSPACE}/control") &&
      strcontains(one([
        for container in one(one(job.template).template).containers : container
        if container.name == "upload"
      ]).args[4], "$${CONTROL_DIR}/upload.ok")
    ])
    error_message = "Backup jobs must retain the exact database producer and create-only stock uploader."
  }

  assert {
    condition = (
      one([
        for volume in one(one(google_cloud_run_v2_job.postgres_backup["json_keys"].template).template).volumes : volume
        if volume.name == "database-password"
      ]).secret[0].secret == "projects/agora-management-test/secrets/production-json-keys-postgres-backup-password" &&
      one([
        for volume in one(one(google_cloud_run_v2_job.postgres_backup["json_keys"].template).template).volumes : volume
        if volume.name == "database-password"
      ]).secret[0].items[0].version == "7" &&
      one([
        for volume in one(one(google_cloud_run_v2_job.postgres_backup["json_keys"].template).template).volumes : volume
        if volume.name == "database-password"
      ]).secret[0].items[0].mode == 256
    )
    error_message = "The JSON Keys backup credential must be an exact numeric secret version mounted as a 0400 file."
  }

  assert {
    condition = alltrue([
      for key, job in google_cloud_run_v2_job.postgres_restore :
      one(one(job.template).template).service_account == var.runtime_service_accounts.restore &&
      one(one(job.template).template).max_retries == 0 &&
      one(one(job.template).template).timeout == "3600s" &&
      one(one(one(job.template).template).vpc_access).egress == "ALL_TRAFFIC" &&
      toset(one(one(one(job.template).template).vpc_access).network_interfaces[0].tags) == toset(["agora-restore"]) &&
      one([
        for volume in one(one(job.template).template).volumes : volume
        if volume.name == "backups"
      ]).gcs[0].read_only &&
      one([
        for environment in one(one(one(job.template).template).containers).env : environment.value
        if environment.name == "EXPECTED_EXTENSIONS"
      ]) == "plpgsql,uuid-ossp" &&
      one([
        for environment in one(one(one(job.template).template).containers).env : environment.value
        if environment.name == "SOURCE_PROJECT_ID"
      ]) == var.workload_project_id &&
      one([
        for environment in one(one(one(job.template).template).containers).env : environment.value
        if environment.name == "DATABASE_HOST"
      ]) == var.database_private_ip &&
      one([
        for environment in one(one(one(job.template).template).containers).env : environment.value
        if environment.name == "DATABASE_PORT"
      ]) == tostring(local.database_contracts[key].port) &&
      strcontains(one(one(one(job.template).template).containers).args[0], "[a-z0-9_]*") &&
      strcontains(one(one(one(job.template).template).containers).args[0], "--single-transaction")
    ])
    error_message = "Restore drills must use fresh single-transaction clusters, read-only storage, and no retry."
  }

  assert {
    condition = (
      one(one(google_cloud_run_v2_job.postgres_backup_monitor[0].template).template).service_account == var.runtime_service_accounts.restore &&
      one(one(google_cloud_run_v2_job.postgres_backup_monitor[0].template).template).timeout == "300s" &&
      strcontains(one(one(one(google_cloud_run_v2_job.postgres_backup_monitor[0].template).template).containers).args[0], "RPO_SECONDS") &&
      strcontains(one(one(one(google_cloud_run_v2_job.postgres_backup_monitor[0].template).template).containers).args[0], "EXPECTED_KEYS") &&
      one(google_cloud_scheduler_job.postgres_backup_monitor[0].http_target).oauth_token[0].service_account_email == var.runtime_service_accounts.scheduler_invoker &&
      google_cloud_scheduler_job.postgres_backup_monitor[0].schedule == "5 * * * *"
    )
    error_message = "The hourly read-only RPO and storage monitor changed."
  }

  assert {
    condition = (
      google_cloud_scheduler_job.postgres_backup["json_keys"].schedule == "15 */4 * * *" &&
      google_cloud_scheduler_job.postgres_backup["authentication"].schedule == "45 */4 * * *" &&
      google_cloud_scheduler_job.postgres_restore["json_keys"].schedule == "15 3 1 * *" &&
      google_cloud_scheduler_job.postgres_restore["authentication"].schedule == "45 3 1 * *" &&
      alltrue([
        for schedule in concat(
          values(google_cloud_scheduler_job.postgres_backup),
          values(google_cloud_scheduler_job.postgres_restore),
        ) :
        schedule.time_zone == "Etc/UTC" &&
        one(schedule.http_target).http_method == "POST" &&
        one(schedule.http_target).oauth_token[0].service_account_email == var.runtime_service_accounts.scheduler_invoker &&
        endswith(one(schedule.http_target).uri, ":run")
      ])
    )
    error_message = "Backup and monthly restore schedules must remain staggered and authenticated."
  }

  assert {
    condition = (
      length(google_cloud_run_v2_job_iam_member.backup_scheduler) == 2 &&
      length(google_cloud_run_v2_job_iam_member.restore_scheduler) == 2 &&
      length(google_cloud_run_v2_job_iam_member.monitor_scheduler) == 1 &&
      alltrue([
        for binding in concat(
          values(google_cloud_run_v2_job_iam_member.backup_scheduler),
          values(google_cloud_run_v2_job_iam_member.restore_scheduler),
          google_cloud_run_v2_job_iam_member.monitor_scheduler,
        ) :
        binding.role == "roles/run.invoker" &&
        binding.member == "serviceAccount:${var.runtime_service_accounts.scheduler_invoker}"
      ])
    )
    error_message = "Only the scheduler identity may invoke the five automatic recovery jobs."
  }
}

run "rejects_an_invalid_project_id" {
  command = plan

  variables {
    workload_project_id = "INVALID"
  }

  expect_failures = [var.workload_project_id]
}

run "rejects_a_partial_database_recovery_release" {
  command = plan

  variables {
    database_releases = {
      json_keys = {
        image                   = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/database@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        backup_password_version = 7
      }
    }
  }

  expect_failures = [var.database_releases]
}

run "rejects_an_unpromoted_database_image" {
  command = plan

  variables {
    database_releases = {
      authentication = {
        image                   = "ghcr.io/a-novel/service-authentication/database@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        backup_password_version = 11
      }
      json_keys = {
        image                   = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/database@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        backup_password_version = 7
      }
    }
  }

  expect_failures = [check.database_images_are_promoted]
}
