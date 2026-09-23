mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = { email = "agora-json-keys-scheduler@agora-json-keys-test.iam.gserviceaccount.com" }
  }
}

variables {
  runtime = {
    schema_version        = 1
    project_id            = "agora-json-keys-test"
    service               = "json-keys"
    region                = "europe-west1"
    service_account       = "agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com"
    notification_channels = ["projects/agora-json-keys-test/notificationChannels/123"]
  }
}

run "json_keys_job_authority" {
  command = plan
  module { source = "../../modules/service-job-access" }

  override_resource {
    target = google_project_iam_custom_role.job_update
    values = { name = "projects/agora-json-keys-test/roles/agoraApplicationJobUpdate" }
  }
  override_resource {
    target = google_project_iam_custom_role.operation_read
    values = { name = "projects/agora-json-keys-test/roles/agoraApplicationJobOperationRead" }
  }

  assert {
    condition = google_project_iam_custom_role.job_update.permissions == toset([
      "run.jobs.get", "run.jobs.update", "run.executions.get", "run.executions.list",
    ]) && google_project_iam_custom_role.job_update.project == var.runtime.project_id
    error_message = "Job updates and execution inspection need no create/delete, IAM, override or cancellation permissions."
  }
  assert {
    condition = { for job, grant in google_cloud_run_v2_job_iam_member.update : job => [grant.project, grant.location, grant.name, grant.role, grant.member] } == {
      for job in ["agora-json-keys-migrations", "agora-json-keys-rotatekeys"] : job => [
        var.runtime.project_id, var.runtime.region, job,
        "projects/agora-json-keys-test/roles/agoraApplicationJobUpdate",
        "serviceAccount:infra-release@agora-json-keys-test.iam.gserviceaccount.com",
      ]
    }
    error_message = "Update authority must attach to both exact application jobs, excluding the probe and initializer."
  }
  assert {
    condition = { for job, grant in google_cloud_run_v2_job_iam_member.execute : job => [grant.project, grant.location, grant.name, grant.role, grant.member] } == {
      for job in ["agora-json-keys-migrations", "agora-json-keys-rotatekeys"] : job => [
        var.runtime.project_id, var.runtime.region, job, "roles/run.invoker",
        "serviceAccount:infra-release@agora-json-keys-test.iam.gserviceaccount.com",
      ]
    }
    error_message = "Only the selected service release may execute its application jobs."
  }
  assert {
    condition = (google_project_iam_custom_role.operation_read.permissions == toset(["run.operations.get"]) &&
      google_project_iam_custom_role.operation_read.project == var.runtime.project_id &&
      [google_project_iam_member.operation_read.project, google_project_iam_member.operation_read.role, google_project_iam_member.operation_read.member] == [
        var.runtime.project_id, "projects/agora-json-keys-test/roles/agoraApplicationJobOperationRead",
        "serviceAccount:infra-release@agora-json-keys-test.iam.gserviceaccount.com",
    ])
    error_message = "Project-level authority must only observe operations."
  }
  assert {
    condition = [google_service_account_iam_member.attach_runtime.service_account_id,
      google_service_account_iam_member.attach_runtime.role, google_service_account_iam_member.attach_runtime.member] == [
      "projects/agora-json-keys-test/serviceAccounts/agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com",
      "roles/iam.serviceAccountUser", "serviceAccount:infra-release@agora-json-keys-test.iam.gserviceaccount.com",
    ]
    error_message = "Attach only this service's application runtime, without token-minting authority."
  }

  assert {
    condition = [for account in google_service_account.rotation : [account.project, account.account_id]] == [
      [var.runtime.project_id, "agora-json-keys-scheduler"],
    ]
    error_message = "Only JSON Keys needs the dedicated, same-project scheduler identity."
  }
  assert {
    condition = [for grant in google_cloud_run_v2_job_iam_member.rotation : [grant.project, grant.location, grant.name, grant.role, grant.member]] == [[
      var.runtime.project_id, var.runtime.region, "agora-json-keys-rotatekeys", "roles/run.invoker",
      "serviceAccount:agora-json-keys-scheduler@agora-json-keys-test.iam.gserviceaccount.com",
    ]]
    error_message = "Scheduled invocation must be bound only to the selected rotation job."
  }
  assert {
    condition = jsonencode([for schedule in google_cloud_scheduler_job.rotation : {
      project        = schedule.project
      region         = schedule.region
      name           = schedule.name
      cadence        = schedule.schedule
      zone           = schedule.time_zone
      paused         = schedule.paused
      deadline       = schedule.attempt_deadline
      deletion       = schedule.deletion_policy
      retries        = schedule.retry_config[0].retry_count
      retry_duration = schedule.retry_config[0].max_retry_duration
      method         = schedule.http_target[0].http_method
      uri            = schedule.http_target[0].uri
      headers        = schedule.http_target[0].headers
      body           = base64decode(schedule.http_target[0].body)
      oauth          = schedule.http_target[0].oauth_token[0]
      }]) == jsonencode([{
      project        = var.runtime.project_id
      region         = var.runtime.region
      name           = "agora-json-keys-rotation"
      cadence        = "10 * * * *"
      zone           = "Etc/UTC"
      paused         = true
      deadline       = "180s"
      deletion       = "PREVENT"
      retries        = 0
      retry_duration = "0s"
      method         = "POST"
      uri            = "https://run.googleapis.com/v2/projects/agora-json-keys-test/locations/europe-west1/jobs/agora-json-keys-rotatekeys:run"
      headers        = { "Content-Type" = "application/json" }
      body           = "{}"
      oauth = {
        service_account_email = "agora-json-keys-scheduler@agora-json-keys-test.iam.gserviceaccount.com"
        scope                 = "https://www.googleapis.com/auth/cloud-platform"
      }
    }])
    error_message = "Keep the exact hourly OAuth request paused, with no overrides or dispatch retries."
  }

  assert {
    condition = [google_monitoring_alert_policy.jobs.project, google_monitoring_alert_policy.jobs.severity,
      google_monitoring_alert_policy.jobs.combiner, tostring(google_monitoring_alert_policy.jobs.enabled)] == [
      "agora-json-keys-test", "ERROR", "OR", "true",
    ] && toset(google_monitoring_alert_policy.jobs.notification_channels) == toset(["projects/agora-json-keys-test/notificationChannels/123"])
    error_message = "Deliver enabled service-job incidents only to this project's operations channel."
  }
  assert {
    condition = jsonencode({ for condition in google_monitoring_alert_policy.jobs.conditions : condition.display_name => {
      thresholds = [for rule in condition.condition_threshold : {
        filter      = rule.filter, comparison = rule.comparison, value = rule.threshold_value, duration = rule.duration
        missing     = rule.evaluation_missing_data
        aggregation = [for a in rule.aggregations : [a.alignment_period, a.per_series_aligner]]
        trigger     = rule.trigger[0].count
      }]
      absent = [for rule in condition.condition_absent : {
        filter      = rule.filter, duration = rule.duration, trigger = rule.trigger[0].count
        aggregation = [for a in rule.aggregations : [a.alignment_period, a.per_series_aligner]]
      }]
      } }) == jsonencode({
      "Application job execution unsuccessful" = {
        thresholds = [{
          filter      = "resource.type=\"cloud_run_job\" AND resource.labels.project_id=\"agora-json-keys-test\" AND resource.labels.location=\"europe-west1\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result!=\"succeeded\" AND (resource.labels.job_name=\"agora-json-keys-migrations\" OR resource.labels.job_name=\"agora-json-keys-rotatekeys\")"
          comparison  = "COMPARISON_GT", value = 0, duration = "0s", missing = null
          aggregation = [["300s", "ALIGN_SUM"]], trigger = 1
        }]
        absent = []
      }
      "No successful rotation in three hours" = {
        thresholds = [{
          filter      = "resource.type=\"cloud_run_job\" AND resource.labels.project_id=\"agora-json-keys-test\" AND resource.labels.location=\"europe-west1\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND resource.labels.job_name=\"agora-json-keys-rotatekeys\" AND metric.labels.result=\"succeeded\""
          comparison  = "COMPARISON_LT", value = 1, duration = "60s", missing = "EVALUATION_MISSING_DATA_INACTIVE"
          aggregation = [["10800s", "ALIGN_SUM"]], trigger = 1
        }]
        absent = []
      }
      "Rotation success telemetry absent for three hours" = {
        thresholds = []
        absent = [{
          filter   = "resource.type=\"cloud_run_job\" AND resource.labels.project_id=\"agora-json-keys-test\" AND resource.labels.location=\"europe-west1\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND resource.labels.job_name=\"agora-json-keys-rotatekeys\" AND metric.labels.result=\"succeeded\""
          duration = "10800s", aggregation = [["300s", "ALIGN_SUM"]], trigger = 1
        }]
      }
    })
    error_message = "Monitor exact own-job failures and both observed-zero and missing rotation successes; never treat one minute without a sample as a three-hour gap."
  }
}

run "authentication_has_only_migrations" {
  command = plan
  module { source = "../../modules/service-job-access" }
  variables {
    runtime = {
      schema_version        = 1
      project_id            = "agora-authentication-test"
      service               = "authentication"
      region                = "europe-west4"
      service_account       = "agora-authentication@agora-authentication-test.iam.gserviceaccount.com"
      notification_channels = ["projects/agora-authentication-test/notificationChannels/456"]
    }
  }

  assert {
    condition = alltrue([for grants in [google_cloud_run_v2_job_iam_member.update, google_cloud_run_v2_job_iam_member.execute] :
      { for job, grant in grants : job => [grant.project, grant.location, grant.name, grant.member] } == {
        "agora-authentication-migrations" = ["agora-authentication-test", "europe-west4", "agora-authentication-migrations",
        "serviceAccount:infra-release@agora-authentication-test.iam.gserviceaccount.com"]
      }
    ])
    error_message = "Authentication gets only its own migration job, project, region and release principal."
  }
  assert {
    condition = (google_service_account_iam_member.attach_runtime.service_account_id ==
    "projects/agora-authentication-test/serviceAccounts/agora-authentication@agora-authentication-test.iam.gserviceaccount.com")
    error_message = "Authentication cannot attach the JSON Keys runtime."
  }
  assert {
    condition = (length(google_service_account.rotation) == 0 &&
    length(google_cloud_scheduler_job.rotation) == 0 && length(google_cloud_run_v2_job_iam_member.rotation) == 0)
    error_message = "Authentication must have no rotation identity, schedule or scheduled invocation grant."
  }
  assert {
    condition = [for condition in google_monitoring_alert_policy.jobs.conditions : condition.condition_threshold[0].filter] == [
      "resource.type=\"cloud_run_job\" AND resource.labels.project_id=\"agora-authentication-test\" AND resource.labels.location=\"europe-west4\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result!=\"succeeded\" AND (resource.labels.job_name=\"agora-authentication-migrations\")",
    ] && toset(google_monitoring_alert_policy.jobs.notification_channels) == toset(["projects/agora-authentication-test/notificationChannels/456"])
    error_message = "Authentication monitors only its migrations and never waits for JSON Keys rotation."
  }
}

run "reject_peer_runtime" {
  command = plan
  module { source = "../../modules/service-job-access" }
  variables {
    runtime = {
      schema_version        = 1, project_id = "agora-json-keys-test", service = "json-keys", region = "europe-west1"
      service_account       = "agora-json-keys@another-project.iam.gserviceaccount.com"
      notification_channels = ["projects/agora-json-keys-test/notificationChannels/123"]
    }
  }
  expect_failures = [var.runtime]
}

run "reject_unknown_service" {
  command = plan
  module { source = "../../modules/service-job-access" }
  variables {
    runtime = {
      schema_version        = 1, project_id = "agora-json-keys-test", service = "genai", region = "europe-west1"
      service_account       = "agora-genai@agora-json-keys-test.iam.gserviceaccount.com"
      notification_channels = ["projects/agora-json-keys-test/notificationChannels/123"]
    }
  }
  expect_failures = [var.runtime]
}

run "reject_unknown_contract" {
  command = plan
  module { source = "../../modules/service-job-access" }
  variables {
    runtime = {
      schema_version        = 2, project_id = "agora-json-keys-test", service = "json-keys", region = "europe-west1"
      service_account       = "agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com"
      notification_channels = ["projects/agora-json-keys-test/notificationChannels/123"]
    }
  }
  expect_failures = [var.runtime]
}

run "reject_zone_as_region" {
  command = plan
  module { source = "../../modules/service-job-access" }
  variables {
    runtime = {
      schema_version        = 1, project_id = "agora-json-keys-test", service = "json-keys", region = "europe-west1-d"
      service_account       = "agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com"
      notification_channels = ["projects/agora-json-keys-test/notificationChannels/123"]
    }
  }
  expect_failures = [var.runtime]
}

run "reject_project_resource_path" {
  command = plan
  module { source = "../../modules/service-job-access" }
  variables {
    runtime = {
      schema_version        = 1, project_id = "projects/agora-json-keys-test", service = "json-keys", region = "europe-west1"
      service_account       = "agora-json-keys@projects/agora-json-keys-test.iam.gserviceaccount.com"
      notification_channels = ["projects/agora-json-keys-test/notificationChannels/123"]
    }
  }
  expect_failures = [var.runtime]
}

run "reject_peer_channel" {
  command = plan
  module { source = "../../modules/service-job-access" }
  variables {
    runtime = {
      schema_version        = 1, project_id = "agora-json-keys-test", service = "json-keys", region = "europe-west1"
      service_account       = "agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com"
      notification_channels = ["projects/agora-authentication-test/notificationChannels/123"]
    }
  }
  expect_failures = [var.runtime]
}

run "reject_unmonitored_jobs" {
  command = plan
  module { source = "../../modules/service-job-access" }
  variables {
    runtime = {
      schema_version        = 1, project_id = "agora-json-keys-test", service = "json-keys", region = "europe-west1"
      service_account       = "agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com"
      notification_channels = []
    }
  }
  expect_failures = [var.runtime]
}
