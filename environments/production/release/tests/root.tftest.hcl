mock_provider "google" {
  mock_resource "google_cloud_run_v2_service" {
    defaults = {
      uri = "https://agora-json-keys-grpc-test.europe-west1.run.app"
    }
  }
}

variables {
  management_project_id = "agora-management-test"
  workload_project_id   = "agora-production-test"
  backup_bucket_name    = "agora-management-test-123456789012-backups"
  database_private_ip   = "10.20.0.5"
  network_id            = "projects/agora-production-test/global/networks/agora-production"
  subnet_id             = "projects/agora-production-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
  cloud_run_invocation_tags = {
    key = "tagKeys/100000000001"
    values = {
      initializer = "tagValues/200000000001"
      internal    = "tagValues/200000000002"
      recovery    = "tagValues/200000000003"
      release     = "tagValues/200000000004"
      scheduled   = "tagValues/200000000005"
    }
  }
  runtime_service_accounts = {
    authentication    = "agora-authentication@agora-production-test.iam.gserviceaccount.com"
    backup            = "agora-backup@agora-production-test.iam.gserviceaccount.com"
    json_keys         = "agora-json-keys@agora-production-test.iam.gserviceaccount.com"
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
      length(google_cloud_scheduler_job.postgres_backup_monitor) == 0 &&
      length(google_cloud_run_v2_job.application) == 0 &&
      length(google_cloud_scheduler_job.json_keys_rotation) == 0 &&
      length(google_cloud_run_v2_service.json_keys) == 0 &&
      length(google_cloud_run_v2_service.authentication) == 0 &&
      length(google_tags_location_tag_binding.application) == 0 &&
      length(google_tags_location_tag_binding.postgres_backup) == 0 &&
      length(google_tags_location_tag_binding.postgres_restore) == 0 &&
      length(google_tags_location_tag_binding.postgres_recover) == 0 &&
      length(google_tags_location_tag_binding.postgres_backup_monitor) == 0 &&
      length(google_tags_location_tag_binding.json_keys) == 0 &&
      length(google_tags_location_tag_binding.authentication) == 0
    )
    error_message = "No recovery or application runtime may exist before its release contract is enabled."
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
      job.launch_stage == "BETA" &&
      one(job.template).task_count == 1 &&
      one(job.template).parallelism == 1 &&
      one(one(job.template).template).service_account == var.runtime_service_accounts.backup &&
      one(one(job.template).template).max_retries == 1 &&
      one(one(job.template).template).timeout == "1800s" &&
      one(one(job.template).template).execution_environment == "EXECUTION_ENVIRONMENT_GEN2" &&
      one([
        for volume in one(one(job.template).template).volumes : volume
        if volume.name == "workspace"
      ]).empty_dir[0].size_limit == "10Gi" &&
      one(one(one(job.template).template).vpc_access).egress == "ALL_TRAFFIC" &&
      toset(one(one(one(job.template).template).vpc_access).network_interfaces[0].tags) == toset(["agora-backup"])
    ])
    error_message = "Backup jobs lost their singleton, Preview disk, retry, timeout, identity, or deny-by-default VPC contract."
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
      job.launch_stage == "BETA" &&
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
        for volume in one(one(job.template).template).volumes : volume
        if volume.name == "workspace"
      ]).empty_dir[0].size_limit == "10Gi" &&
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
    error_message = "Restore drills must use fresh single-transaction clusters, a bounded Preview disk, read-only storage, and no retry."
  }

  assert {
    condition = (
      one(one(google_cloud_run_v2_job.postgres_backup_monitor[0].template).template).service_account == var.runtime_service_accounts.restore &&
      one(one(google_cloud_run_v2_job.postgres_backup_monitor[0].template).template).timeout == "300s" &&
      strcontains(one(one(one(google_cloud_run_v2_job.postgres_backup_monitor[0].template).template).containers).args[0], "RPO_SECONDS") &&
      strcontains(one(one(one(google_cloud_run_v2_job.postgres_backup_monitor[0].template).template).containers).args[0], "EXPECTED_KEYS") &&
      one([
        for environment in one(one(one(google_cloud_run_v2_job.postgres_backup_monitor[0].template).template).containers).env : environment.value
        if environment.name == "STORAGE_ALERT_BYTES"
      ]) == "268435456000" &&
      one(google_cloud_scheduler_job.postgres_backup_monitor[0].http_target).oauth_token[0].service_account_email == var.runtime_service_accounts.scheduler_invoker &&
      google_cloud_scheduler_job.postgres_backup_monitor[0].schedule == "5 * * * *" &&
      one(google_cloud_scheduler_job.postgres_backup_monitor[0].retry_config).max_doublings == 5 &&
      google_cloud_scheduler_job.postgres_backup_monitor[0].paused == true
    )
    error_message = "The hourly read-only RPO and storage monitor must stay paused until application activation."
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
        schedule.paused == true &&
        schedule.time_zone == "Etc/UTC" &&
        one(schedule.retry_config).max_doublings == 5 &&
        one(schedule.http_target).http_method == "POST" &&
        one(schedule.http_target).oauth_token[0].service_account_email == var.runtime_service_accounts.scheduler_invoker &&
        endswith(one(schedule.http_target).uri, ":run")
      ])
    )
    error_message = "Backup and monthly restore schedules must remain paused before application activation, staggered, and authenticated."
  }

  assert {
    condition = (
      length(google_tags_location_tag_binding.postgres_backup) == 2 &&
      length(google_tags_location_tag_binding.postgres_restore) == 2 &&
      length(google_tags_location_tag_binding.postgres_backup_monitor) == 1 &&
      toset([for binding in concat(values(google_tags_location_tag_binding.postgres_backup), values(google_tags_location_tag_binding.postgres_restore), google_tags_location_tag_binding.postgres_backup_monitor) : binding.parent]) == toset([
        for job in concat(values(google_cloud_run_v2_job.postgres_backup), values(google_cloud_run_v2_job.postgres_restore), google_cloud_run_v2_job.postgres_backup_monitor) :
        "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/jobs/${job.name}"
      ]) &&
      alltrue([
        for binding in concat(
          values(google_tags_location_tag_binding.postgres_backup),
          values(google_tags_location_tag_binding.postgres_restore),
          google_tags_location_tag_binding.postgres_backup_monitor,
        ) : binding.tag_value == var.cloud_run_invocation_tags.values.scheduled && binding.location == var.region
      ])
    )
    error_message = "Every scheduled recovery-point job must carry the foundation-owned scheduled invocation tag."
  }
}

run "builds_the_private_json_keys_and_public_authentication_runtime" {
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
    application_release = {
      rollout = {
        candidate_tag = "c-0123456789abcdef"
        phase         = "active"
      }
      authentication = {
        active_revision = "agora-authentication-rest-0123456789ab"
        images = {
          init       = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/jobs/init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
          migrations = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/jobs/migrations@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
          rest       = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/rest@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        }
        revision = "agora-authentication-rest-0123456789ab"
        secrets = {
          postgres_password_version    = 11
          smtp_password_version        = 12
          super_admin_password_version = 13
        }
        smtp = {
          address       = "smtp.example.com:587"
          sender_domain = "smtp.example.com"
          sender_email  = "noreply@example.com"
          sender_name   = "Agora"
          username      = "smtp-login@example.com"
        }
        super_admin_email = "admin@example.com"
      }
      json_keys = {
        active_revision = "agora-json-keys-grpc-abcdef012345"
        images = {
          grpc        = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/grpc@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
          migrations  = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/jobs/migrations@sha256:1111111111111111111111111111111111111111111111111111111111111111"
          rotate_keys = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/jobs/rotatekeys@sha256:2222222222222222222222222222222222222222222222222222222222222222"
        }
        revision = "agora-json-keys-grpc-abcdef012345"
        secrets = {
          app_master_key_version    = 7
          postgres_password_version = 8
        }
      }
    }
  }

  assert {
    condition = (
      length(google_cloud_run_v2_job.application) == 3 &&
      toset(keys(google_cloud_run_v2_job.application)) == toset([
        "authentication_migrations",
        "json_keys_migrations",
        "json_keys_rotate",
      ]) &&
      alltrue([
        for job in values(google_cloud_run_v2_job.application) :
        !job.deletion_protection &&
        one(job.template).task_count == 1 &&
        one(job.template).parallelism == 1 &&
        one(one(job.template).template).execution_environment == "EXECUTION_ENVIRONMENT_GEN2" &&
        one(one(one(job.template).template).containers).resources[0].limits == tomap({
          cpu    = "1"
          memory = "512Mi"
        }) &&
        one(one(one(job.template).template).vpc_access).egress == "ALL_TRAFFIC" &&
        one(one(one(job.template).template).vpc_access).network_interfaces[0].network == var.network_id &&
        one(one(one(job.template).template).vpc_access).network_interfaces[0].subnetwork == var.subnet_id
      ])
    )
    error_message = "Application jobs must remain three singleton, bounded, scale-to-zero Direct VPC executions."
  }

  assert {
    condition = {
      for key, job in google_cloud_run_v2_job.application : key => {
        binding_valid = (google_tags_location_tag_binding.application[key].parent == "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/jobs/${job.name}" && google_tags_location_tag_binding.application[key].location == var.region)
        identity      = one(one(job.template).template).service_account
        max_retries   = one(one(job.template).template).max_retries
        name          = job.name
        timeout       = one(one(job.template).template).timeout
        vpc_tag       = one(one(one(job.template).template).vpc_access).network_interfaces[0].tags[0]
        invocation    = google_tags_location_tag_binding.application[key].tag_value
      }
      } == {
      authentication_migrations = {
        binding_valid = true
        identity      = var.runtime_service_accounts.authentication
        max_retries   = 0
        name          = "agora-authentication-migrations"
        timeout       = "600s"
        vpc_tag       = "agora-authentication"
        invocation    = var.cloud_run_invocation_tags.values.release
      }
      json_keys_migrations = {
        binding_valid = true
        identity      = var.runtime_service_accounts.json_keys
        max_retries   = 0
        name          = "agora-json-keys-migrations"
        timeout       = "600s"
        vpc_tag       = "agora-json-keys"
        invocation    = var.cloud_run_invocation_tags.values.release
      }
      json_keys_rotate = {
        binding_valid = true
        identity      = var.runtime_service_accounts.json_keys
        max_retries   = 1
        name          = "agora-json-keys-rotatekeys"
        timeout       = "300s"
        vpc_tag       = "agora-json-keys"
        invocation    = var.cloud_run_invocation_tags.values.scheduled
      }
    }
    error_message = "Every application job must retain its exact identity, retry, timeout, name, and database path."
  }

  assert {
    condition = (
      length(google_cloud_scheduler_job.json_keys_rotation) == 1 &&
      google_cloud_scheduler_job.json_keys_rotation[0].schedule == "10 * * * *" &&
      google_cloud_scheduler_job.json_keys_rotation[0].paused == false &&
      google_cloud_scheduler_job.json_keys_rotation[0].time_zone == "Etc/UTC" &&
      google_cloud_scheduler_job.json_keys_rotation[0].retry_config[0].retry_count == 1 &&
      one(google_cloud_scheduler_job.json_keys_rotation[0].retry_config).max_doublings == 5 &&
      one(google_cloud_scheduler_job.json_keys_rotation[0].http_target).uri == "https://run.googleapis.com/v2/projects/agora-production-test/locations/europe-west1/jobs/agora-json-keys-rotatekeys:run" &&
      one(google_cloud_scheduler_job.json_keys_rotation[0].http_target).oauth_token[0].service_account_email == var.runtime_service_accounts.scheduler_invoker
    )
    error_message = "The tagged idempotent JSON Keys rotation job must remain scheduled hourly."
  }

  assert {
    condition = (
      one([
        for environment in one(one(one(google_cloud_run_v2_job.application["authentication_migrations"].template).template).containers).env : environment
        if environment.name == "POSTGRES_PASSWORD"
      ]).value_source[0].secret_key_ref[0].secret == "projects/agora-management-test/secrets/production-authentication-postgres-password" &&
      one([
        for environment in one(one(one(google_cloud_run_v2_job.application["authentication_migrations"].template).template).containers).env : environment
        if environment.name == "POSTGRES_PASSWORD"
      ]).value_source[0].secret_key_ref[0].version == "11" &&
      alltrue([
        for key in ["json_keys_migrations", "json_keys_rotate"] :
        one([
          for environment in one(one(one(google_cloud_run_v2_job.application[key].template).template).containers).env : environment
          if environment.name == "POSTGRES_PASSWORD"
        ]).value_source[0].secret_key_ref[0].secret == "projects/agora-management-test/secrets/production-json-keys-postgres-password" &&
        one([
          for environment in one(one(one(google_cloud_run_v2_job.application[key].template).template).containers).env : environment
          if environment.name == "POSTGRES_PASSWORD"
        ]).value_source[0].secret_key_ref[0].version == "8"
      ]) &&
      toset([
        for environment in one(one(one(google_cloud_run_v2_job.application["authentication_migrations"].template).template).containers).env : environment.name
        if length(environment.value_source) == 1
      ]) == toset(["POSTGRES_PASSWORD"]) &&
      toset([
        for environment in one(one(one(google_cloud_run_v2_job.application["json_keys_migrations"].template).template).containers).env : environment.name
        if length(environment.value_source) == 1
      ]) == toset(["POSTGRES_PASSWORD"]) &&
      toset([
        for environment in one(one(one(google_cloud_run_v2_job.application["json_keys_rotate"].template).template).containers).env : environment.name
        if length(environment.value_source) == 1
      ]) == toset(["APP_MASTER_KEY", "POSTGRES_PASSWORD"]) &&
      !contains(keys(google_cloud_run_v2_job.application), "authentication_init") &&
      one([
        for environment in one(one(one(google_cloud_run_v2_job.application["json_keys_rotate"].template).template).containers).env : environment
        if environment.name == "APP_MASTER_KEY"
        ]).value_source[0].secret_key_ref[0] == {
        secret  = "projects/agora-management-test/secrets/production-json-keys-app-master-key"
        version = "7"
      }
    )
    error_message = "Automated application jobs must receive only their declared exact secret versions; initialization stays absent."
  }

  assert {
    condition = (
      local.application_database_environment == {
        authentication = {
          POSTGRES_HOST        = "10.20.0.5"
          POSTGRES_PORT        = "5433"
          POSTGRES_USER        = "agora_authentication"
          POSTGRES_DATABASE    = "agora_authentication"
          POSTGRES_TLS_ENABLED = "false"
        }
        json_keys = {
          POSTGRES_HOST        = "10.20.0.5"
          POSTGRES_PORT        = "5432"
          POSTGRES_USER        = "agora_json_keys"
          POSTGRES_DATABASE    = "agora_json_keys"
          POSTGRES_TLS_ENABLED = "false"
        }
      } &&
      alltrue([
        for key, expected in {
          authentication_migrations = local.application_database_environment.authentication
          json_keys_migrations      = local.application_database_environment.json_keys
          json_keys_rotate          = local.application_database_environment.json_keys
          } : {
          for environment in one(one(one(google_cloud_run_v2_job.application[key].template).template).containers).env :
          environment.name => environment.value
          if contains(keys(expected), environment.name) && length(environment.value_source) == 0
        } == expected
      ]) &&
      {
        for environment in one(one(google_cloud_run_v2_service.json_keys[0].template).containers).env :
        environment.name => environment.value
        if contains(keys(local.application_database_environment.json_keys), environment.name) && length(environment.value_source) == 0
      } == local.application_database_environment.json_keys &&
      {
        for environment in one(one(google_cloud_run_v2_service.authentication[0].template).containers).env :
        environment.name => environment.value
        if contains(keys(local.application_database_environment.authentication), environment.name) && length(environment.value_source) == 0
      } == local.application_database_environment.authentication
    )
    error_message = "Every application runtime must receive its exact discrete private-database settings."
  }

  assert {
    condition = (
      length(google_cloud_run_v2_service.json_keys) == 1 &&
      google_cloud_run_v2_service.json_keys[0].ingress == "INGRESS_TRAFFIC_INTERNAL_ONLY" &&
      google_tags_location_tag_binding.json_keys[0].tag_value == var.cloud_run_invocation_tags.values.internal &&
      google_tags_location_tag_binding.json_keys[0].parent == "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/services/${google_cloud_run_v2_service.json_keys[0].name}" &&
      google_tags_location_tag_binding.json_keys[0].location == var.region &&
      !google_cloud_run_v2_service.json_keys[0].invoker_iam_disabled &&
      !google_cloud_run_v2_service.json_keys[0].deletion_protection &&
      one(google_cloud_run_v2_service.json_keys[0].scaling).min_instance_count == 0 &&
      one(google_cloud_run_v2_service.json_keys[0].scaling).max_instance_count == 3 &&
      one(google_cloud_run_v2_service.json_keys[0].template).service_account == var.runtime_service_accounts.json_keys &&
      one(google_cloud_run_v2_service.json_keys[0].template).timeout == "60s" &&
      one(google_cloud_run_v2_service.json_keys[0].template).max_instance_request_concurrency == 20 &&
      one(google_cloud_run_v2_service.json_keys[0].template).execution_environment == "EXECUTION_ENVIRONMENT_GEN2" &&
      one(one(google_cloud_run_v2_service.json_keys[0].template).containers).image == var.application_release.json_keys.images.grpc &&
      one(one(google_cloud_run_v2_service.json_keys[0].template).containers).ports[0].name == "h2c" &&
      one(one(google_cloud_run_v2_service.json_keys[0].template).containers).ports[0].container_port == 8080 &&
      one(one(google_cloud_run_v2_service.json_keys[0].template).containers).resources[0].cpu_idle &&
      one(one(google_cloud_run_v2_service.json_keys[0].template).containers).resources[0].limits == tomap({
        cpu    = "1"
        memory = "512Mi"
      }) &&
      length(one(one(google_cloud_run_v2_service.json_keys[0].template).containers).startup_probe) == 1 &&
      one(one(google_cloud_run_v2_service.json_keys[0].template).containers).startup_probe[0].tcp_socket[0].port == 8080 &&
      one(one(google_cloud_run_v2_service.json_keys[0].template).containers).startup_probe[0].initial_delay_seconds == 0 &&
      one(one(google_cloud_run_v2_service.json_keys[0].template).containers).startup_probe[0].timeout_seconds == 1 &&
      one(one(google_cloud_run_v2_service.json_keys[0].template).containers).startup_probe[0].period_seconds == 3 &&
      one(one(google_cloud_run_v2_service.json_keys[0].template).containers).startup_probe[0].failure_threshold == 80 &&
      length(one(one(google_cloud_run_v2_service.json_keys[0].template).containers).liveness_probe) == 0 &&
      one(one(google_cloud_run_v2_service.json_keys[0].template).vpc_access).egress == "ALL_TRAFFIC" &&
      toset(one(one(google_cloud_run_v2_service.json_keys[0].template).vpc_access).network_interfaces[0].tags) == toset(["agora-json-keys"]) &&
      one(google_cloud_run_v2_service.json_keys[0].template).revision == var.application_release.json_keys.revision &&
      one(google_cloud_run_v2_service.json_keys[0].traffic).percent == 100
    )
    error_message = "JSON Keys must remain an internal h2c service with request-based CPU, bounded scaling, TCP startup, and private-only egress."
  }

  assert {
    condition = (
      toset([
        for environment in one(one(google_cloud_run_v2_service.json_keys[0].template).containers).env : environment.name
        if length(environment.value_source) == 1
      ]) == toset(["APP_MASTER_KEY", "POSTGRES_PASSWORD"]) &&
      one([
        for environment in one(one(google_cloud_run_v2_service.json_keys[0].template).containers).env : environment
        if environment.name == "APP_MASTER_KEY"
        ]).value_source[0].secret_key_ref[0] == {
        secret  = "projects/agora-management-test/secrets/production-json-keys-app-master-key"
        version = "7"
      } &&
      one([
        for environment in one(one(google_cloud_run_v2_service.json_keys[0].template).containers).env : environment
        if environment.name == "POSTGRES_PASSWORD"
        ]).value_source[0].secret_key_ref[0] == {
        secret  = "projects/agora-management-test/secrets/production-json-keys-postgres-password"
        version = "8"
      }
    )
    error_message = "JSON Keys may resolve only its exact master-key and owner-password versions."
  }

  assert {
    condition = (
      length(google_cloud_run_v2_service.authentication) == 1 &&
      google_cloud_run_v2_service.authentication[0].ingress == "INGRESS_TRAFFIC_ALL" &&
      google_cloud_run_v2_service.authentication[0].invoker_iam_disabled &&
      length(google_tags_location_tag_binding.authentication) == 0 &&
      !google_cloud_run_v2_service.authentication[0].deletion_protection &&
      one(google_cloud_run_v2_service.authentication[0].scaling).min_instance_count == 0 &&
      one(google_cloud_run_v2_service.authentication[0].scaling).max_instance_count == 3 &&
      one(google_cloud_run_v2_service.authentication[0].template).service_account == var.runtime_service_accounts.authentication &&
      one(google_cloud_run_v2_service.authentication[0].template).timeout == "60s" &&
      one(google_cloud_run_v2_service.authentication[0].template).max_instance_request_concurrency == 20 &&
      one(one(google_cloud_run_v2_service.authentication[0].template).containers).image == var.application_release.authentication.images.rest &&
      !one(one(google_cloud_run_v2_service.authentication[0].template).containers).resources[0].cpu_idle &&
      one(one(google_cloud_run_v2_service.authentication[0].template).containers).resources[0].limits == tomap({
        cpu    = "1"
        memory = "512Mi"
      }) &&
      one(one(google_cloud_run_v2_service.authentication[0].template).containers).startup_probe[0].http_get[0].path == "/v2/ping" &&
      one(one(google_cloud_run_v2_service.authentication[0].template).containers).startup_probe[0].initial_delay_seconds == 0 &&
      one(one(google_cloud_run_v2_service.authentication[0].template).containers).startup_probe[0].timeout_seconds == 1 &&
      one(one(google_cloud_run_v2_service.authentication[0].template).containers).startup_probe[0].period_seconds == 3 &&
      one(one(google_cloud_run_v2_service.authentication[0].template).containers).startup_probe[0].failure_threshold == 80 &&
      one(one(google_cloud_run_v2_service.authentication[0].template).containers).liveness_probe[0].http_get[0].path == "/v2/ping" &&
      one(one(google_cloud_run_v2_service.authentication[0].template).vpc_access).egress == "PRIVATE_RANGES_ONLY" &&
      toset(one(one(google_cloud_run_v2_service.authentication[0].template).vpc_access).network_interfaces[0].tags) == toset(["agora-authentication"]) &&
      one(google_cloud_run_v2_service.authentication[0].template).revision == var.application_release.authentication.revision &&
      one(google_cloud_run_v2_service.authentication[0].traffic).percent == 100
    )
    error_message = "Authentication must remain public, scale to zero, drain background mail, and split private from managed public egress."
  }

  assert {
    condition = (
      one([
        for environment in one(one(google_cloud_run_v2_service.authentication[0].template).containers).env : environment
        if environment.name == "GCLOUD_PROJECT_ID"
      ]).value == var.workload_project_id &&
      one([
        for environment in one(one(google_cloud_run_v2_service.authentication[0].template).containers).env : environment
        if environment.name == "SERVICE_JSON_KEYS_HOST"
      ]).value == "agora-json-keys-grpc-test.europe-west1.run.app" &&
      one([
        for environment in one(one(google_cloud_run_v2_service.authentication[0].template).containers).env : environment
        if environment.name == "SERVICE_JSON_KEYS_PORT"
      ]).value == "443" &&
      one([
        for environment in one(one(google_cloud_run_v2_service.authentication[0].template).containers).env : environment
        if environment.name == "REST_TIMEOUT_SHUTDOWN"
      ]).value == "9s" &&
      one([
        for environment in one(one(google_cloud_run_v2_service.authentication[0].template).containers).env : environment
        if environment.name == "SMTP_TIMEOUT"
      ]).value == "5s" &&
      one([
        for environment in one(one(google_cloud_run_v2_service.authentication[0].template).containers).env : environment
        if environment.name == "SMTP_USERNAME"
      ]).value == "smtp-login@example.com" &&
      toset([
        for environment in one(one(google_cloud_run_v2_service.authentication[0].template).containers).env : environment.name
        if length(environment.value_source) == 1
      ]) == toset(["POSTGRES_PASSWORD", "SMTP_SENDER_PASSWORD"]) &&
      one([
        for environment in one(one(google_cloud_run_v2_service.authentication[0].template).containers).env : environment
        if environment.name == "POSTGRES_PASSWORD"
        ]).value_source[0].secret_key_ref[0] == {
        secret  = "projects/agora-management-test/secrets/production-authentication-postgres-password"
        version = "11"
      } &&
      one([
        for environment in one(one(google_cloud_run_v2_service.authentication[0].template).containers).env : environment
        if environment.name == "SMTP_SENDER_PASSWORD"
        ]).value_source[0].secret_key_ref[0] == {
        secret  = "projects/agora-management-test/secrets/production-authentication-smtp-sender-password"
        version = "12"
      } &&
      length([
        for environment in one(one(google_cloud_run_v2_service.authentication[0].template).containers).env : environment
        if environment.name == "SUPER_ADMIN_PASSWORD"
      ]) == 0
    )
    error_message = "Authentication must use the exact JSON Keys audience host, bounded shutdown/mail, and only its REST secrets."
  }
}

run "routes_a_first_release_to_its_only_revisions" {
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
    application_release = {
      rollout = {
        candidate_tag = "c-0123456789abcdef"
        phase         = "candidate"
      }
      authentication = {
        images = {
          init       = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/jobs/init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
          migrations = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/jobs/migrations@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
          rest       = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/rest@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        }
        revision = "agora-authentication-rest-0123456789ab"
        secrets = {
          postgres_password_version    = 11
          smtp_password_version        = 12
          super_admin_password_version = 13
        }
        smtp = {
          address       = "smtp.example.com:587"
          sender_domain = "smtp.example.com"
          sender_email  = "noreply@example.com"
          sender_name   = "Agora"
          username      = "smtp-login@example.com"
        }
        super_admin_email = "admin@example.com"
      }
      json_keys = {
        images = {
          grpc        = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/grpc@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
          migrations  = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/jobs/migrations@sha256:1111111111111111111111111111111111111111111111111111111111111111"
          rotate_keys = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/jobs/rotatekeys@sha256:2222222222222222222222222222222222222222222222222222222222222222"
        }
        revision = "agora-json-keys-grpc-abcdef012345"
        secrets = {
          app_master_key_version    = 7
          postgres_password_version = 8
        }
      }
    }
  }

  assert {
    condition = alltrue([
      for service in [
        google_cloud_run_v2_service.json_keys[0],
        google_cloud_run_v2_service.authentication[0],
        ] : (
        length(service.traffic) == 1 &&
        one(service.traffic).type == "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST" &&
        one(service.traffic).percent == 100 &&
        one(service.traffic).revision == null &&
        one(service.traffic).tag == var.application_release.rollout.candidate_tag
      )
    ])
    error_message = "A first release must route all traffic to its tagged latest revision because no prior revision exists."
  }
}

run "builds_restore_only_contracts_in_a_disposable_recovery_state" {
  command = plan

  variables {
    recovery_mode               = true
    recovery_source_database_ip = "10.30.0.2"
    recovery_source_project_id  = "agora-source-test"
    recovery_backup_attempts = {
      authentication = "1750000000-agora-auth-backup-0"
      json_keys      = "1750000000-agora-json-backup-0"
    }
    recovery_database_password_versions = {
      authentication = 17
      json_keys      = 13
    }
    recovery_database_images = {
      authentication = "europe-west1-docker.pkg.dev/agora-source-test/agora-production/service-authentication/database@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      json_keys      = "europe-west1-docker.pkg.dev/agora-source-test/agora-production/service-json-keys/database@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
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
    application_release = {
      rollout = {
        candidate_tag = "c-0123456789abcdef"
        phase         = "active"
      }
      authentication = {
        active_revision = "agora-authentication-rest-0123456789ab"
        images = {
          init       = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/jobs/init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
          migrations = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/jobs/migrations@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
          rest       = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/rest@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        }
        revision = "agora-authentication-rest-0123456789ab"
        secrets = {
          postgres_password_version    = 11
          smtp_password_version        = 12
          super_admin_password_version = 13
        }
        smtp = {
          address       = "smtp.example.com:587"
          sender_domain = "smtp.example.com"
          sender_email  = "noreply@example.com"
          sender_name   = "Agora"
          username      = "smtp-login@example.com"
        }
        super_admin_email = "admin@example.com"
      }
      json_keys = {
        active_revision = "agora-json-keys-grpc-abcdef012345"
        images = {
          grpc        = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/grpc@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
          migrations  = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/jobs/migrations@sha256:1111111111111111111111111111111111111111111111111111111111111111"
          rotate_keys = "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/jobs/rotatekeys@sha256:2222222222222222222222222222222222222222222222222222222222222222"
        }
        revision = "agora-json-keys-grpc-abcdef012345"
        secrets = {
          app_master_key_version    = 7
          postgres_password_version = 8
        }
      }
    }
  }

  assert {
    condition = (
      length(google_cloud_run_v2_job.postgres_recover) == 2 &&
      length(google_cloud_run_v2_job.postgres_backup) == 0 &&
      length(google_cloud_run_v2_job.postgres_restore) == 0 &&
      length(google_cloud_run_v2_job.postgres_backup_monitor) == 0 &&
      length(google_cloud_scheduler_job.postgres_backup) == 0 &&
      length(google_cloud_scheduler_job.postgres_restore) == 0 &&
      length(google_cloud_scheduler_job.postgres_backup_monitor) == 0 &&
      length(google_cloud_scheduler_job.json_keys_rotation) == 0 &&
      length(google_cloud_run_v2_job.application) == 0 &&
      google_cloud_run_v2_service.authentication[0].ingress == "INGRESS_TRAFFIC_INTERNAL_ONLY" &&
      !google_cloud_run_v2_service.authentication[0].invoker_iam_disabled &&
      google_tags_location_tag_binding.authentication[0].tag_value == var.cloud_run_invocation_tags.values.recovery &&
      google_tags_location_tag_binding.authentication[0].parent == "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/services/${google_cloud_run_v2_service.authentication[0].name}" &&
      google_tags_location_tag_binding.authentication[0].location == var.region &&
      google_tags_location_tag_binding.json_keys[0].tag_value == var.cloud_run_invocation_tags.values.internal &&
      google_tags_location_tag_binding.json_keys[0].parent == "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/services/${google_cloud_run_v2_service.json_keys[0].name}" &&
      google_tags_location_tag_binding.json_keys[0].location == var.region
    )
    error_message = "Disposable recovery must grant only recovery automation and keep schedules, initialization, and public ingress disabled."
  }

  assert {
    condition = alltrue([
      for service in [
        google_cloud_run_v2_service.json_keys[0],
        google_cloud_run_v2_service.authentication[0],
        ] : (
        length(service.traffic) == 1 &&
        one(service.traffic).type == "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST" &&
        one(service.traffic).percent == 100 &&
        one(service.traffic).revision == null
      )
    ])
    error_message = "Disposable recovery must route each newly created service to its latest revision."
  }

  assert {
    condition = alltrue([
      for key, job in google_cloud_run_v2_job.postgres_recover :
      job.name == "agora-postgres-recover-${local.enabled_database_contracts[key].object_key}-${substr(sha256(jsonencode({
        attempt          = var.recovery_backup_attempts[key]
        database_image   = var.recovery_database_images[key]
        password_version = var.recovery_database_password_versions[key]
      })), 0, 8)}" &&
      one(one(job.template).template).service_account == var.runtime_service_accounts.restore &&
      one(one(job.template).template).max_retries == 0 &&
      google_tags_location_tag_binding.postgres_recover[key].tag_value == var.cloud_run_invocation_tags.values.recovery &&
      google_tags_location_tag_binding.postgres_recover[key].parent == "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/jobs/${job.name}" &&
      google_tags_location_tag_binding.postgres_recover[key].location == var.region &&
      toset(one(one(one(job.template).template).vpc_access).network_interfaces[0].tags) == toset(["agora-restore"]) &&
      one([
        for environment in one(one(one(job.template).template).containers).env : environment.value
        if environment.name == "RECOVERY_ATTEMPT"
      ]) == var.recovery_backup_attempts[key] &&
      one([
        for environment in one(one(one(job.template).template).containers).env : environment.value
        if environment.name == "SOURCE_DATABASE_HOST"
      ]) == var.recovery_source_database_ip &&
      one([
        for volume in one(one(job.template).template).volumes : volume
        if volume.name == "database-password"
      ]).secret[0].items[0].version == tostring(var.recovery_database_password_versions[key])
    ])
    error_message = "Recovery jobs must bind the exact attempt, owner secret version, private path, and non-retrying restore identity."
  }
}

run "rejects_an_invalid_project_id" {
  command = plan

  variables {
    workload_project_id = "INVALID"
  }

  expect_failures = [var.workload_project_id]
}

run "rejects_a_non_permanent_invocation_tag" {
  command = plan

  variables {
    cloud_run_invocation_tags = {
      key = "environment"
      values = {
        initializer = "tagValues/200000000001"
        internal    = "tagValues/200000000002"
        recovery    = "tagValues/200000000003"
        release     = "tagValues/200000000004"
        scheduled   = "tagValues/200000000005"
      }
    }
  }

  expect_failures = [var.cloud_run_invocation_tags]
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
