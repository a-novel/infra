locals {
  # Native verify can report damage or an empty repository with exit status zero.
  database_verify_failure_pattern = "(?m)^ *(status: error|no archives or backups exist in the repo) *$"
  database_backup_log_scope = { for key, runtime in local.database_runtime : key => join(" AND ", [
    "resource.type=\"gce_instance\"",
    "resource.labels.project_id=\"${var.project_id}\"",
    "resource.labels.instance_id=\"${data.google_compute_instance.database[key].instance_id}\"",
  ]) }
  database_backup_metric_scope = { for key, runtime in local.database_runtime : key =>
    "monitored_resource=\"gce_instance\", project_id=\"${var.project_id}\", instance_id=\"${data.google_compute_instance.database[key].instance_id}\""
  }
  database_backup_freshness = {
    full = {
      jobs = "agora-backup-full", window = "24h", title = "Sunday full backup missed its 04:00 UTC deadline"
      # Check during Sunday 04:00–23:59 UTC. This is a weekly deadline, not a full-chain age monitor.
      gate = " and (day_of_week() == 0) and (hour() >= 4)"
    }
    backup = { jobs = "agora-backup-(full|diff)", window = "24h45m", title = "No backup success in 24 hours 45 minutes", gate = "" }
    check  = { jobs = "agora-backup-check", window = "3h", title = "No archive check success in three hours", gate = "" }
  }
  database_backup_health_rules = var.database_runtime == null ? {} : merge({
    for name, rule in local.database_backup_freshness : name => {
      title = rule.title
      # Explicit zero handles never-seen/stopped hosts, unlike an absence condition.
      query = "((sum(increase({\"logging.googleapis.com/user/${google_logging_metric.database_backup_success["host"].name}\", ${local.database_backup_metric_scope["host"]}, job=~\"${rule.jobs}\"}[${rule.window}])) or vector(0)) < 1)${rule.gate}"
    }
    }, {
    disk = {
      title = "Database disk above 85%, or disk telemetry missing for one hour"
      query = join(" or ", [
        "max(max_over_time({\"compute.googleapis.com/guest/disk/percent_used\", ${local.database_backup_metric_scope["host"]}}[5m])) > 85",
        "absent_over_time({\"compute.googleapis.com/guest/disk/percent_used\", ${local.database_backup_metric_scope["host"]}}[1h])",
      ])
    }
  })
}

resource "google_logging_metric" "database_backup_success" {
  for_each = local.database_runtime

  project     = var.project_id
  name        = "agora_${var.service}_backup_success"
  description = "Completed native commands, not proof of restorable backup dependencies."
  filter = join(" AND ", [
    local.database_backup_log_scope[each.key],
    "log_id(\"cos_containers\")",
    "jsonPayload.\"cos.googleapis.com/container_name\"=(\"agora-backup-full\" OR \"agora-backup-diff\" OR \"agora-backup-check\")",
    "jsonPayload.message=~\" (backup|check) command end: completed successfully\"",
  ])
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "job"
      value_type  = "STRING"
      description = "One of the three fixed native worker names."
    }
  }
  label_extractors = { job = "EXTRACT(jsonPayload.\"cos.googleapis.com/container_name\")" }
}

resource "google_monitoring_alert_policy" "database_backup_failure" {
  for_each = local.database_runtime

  project               = var.project_id
  display_name          = "Agora ${var.service} native backup failed"
  combiner              = "OR"
  enabled               = false
  severity              = "ERROR"
  notification_channels = [google_monitoring_notification_channel.operations.name]
  deletion_policy       = "DELETE"

  conditions {
    display_name = "pgBackRest, WAL archiving or its systemd worker reported an error"
    condition_matched_log {
      filter = "${local.database_backup_log_scope[each.key]} AND (${join(" OR ", [
        "(log_id(\"cos_containers\") AND jsonPayload.message=~\"(ERROR: \\\\[[0-9]+\\\\]:|archive command failed)\")",
        "(log_id(\"cos_containers\") AND jsonPayload.\"cos.googleapis.com/container_name\"=\"agora-backup-verify\" AND jsonPayload.message=~\"${local.database_verify_failure_pattern}\")",
        "(log_id(\"cos_journal_warning\") AND (jsonPayload.UNIT=~\"^agora-backup-.*[.]service$\" OR jsonPayload._SYSTEMD_UNIT=~\"^agora-backup-.*[.]service$\"))",
      ])})"
    }
  }
  alert_strategy {
    notification_rate_limit { period = "300s" }
    auto_close           = "604800s"
    notification_prompts = ["OPENED"]
  }
  documentation {
    mime_type = "text/markdown"
    content   = "Inspect the selected worker's journal and retained Docker logs. Verify can exit zero with an error report; inspect its [integrity result](https://github.com/a-novel/infra/blob/master/environments/service-foundation/README.md#native-integrity-check). Do not disable WAL archiving, delete WAL, run expiry or retry a restore. Follow [native backup response](https://github.com/a-novel/infra/blob/master/docs/runbooks/respond-to-alerts.md#native-backup-pilot)."
  }
}

resource "google_monitoring_alert_policy" "database_backup_health" {
  for_each = local.database_backup_health_rules

  project               = var.project_id
  display_name          = "Agora ${var.service}: ${each.value.title}"
  combiner              = "OR"
  enabled               = false
  severity              = "ERROR"
  notification_channels = [google_monitoring_notification_channel.operations.name]
  deletion_policy       = "DELETE"

  conditions {
    display_name = each.value.title
    condition_prometheus_query_language {
      query               = each.value.query
      duration            = "600s"
      evaluation_interval = "300s"
    }
  }
  documentation {
    mime_type = "text/markdown"
    content   = "Missing success includes collection failure, a stopped host and jobs that never ran. Inspect native info and archive/check logs; a command success is not restore verification. Disk pressure can include retained WAL after failed archiving. Rebind policies after host replacement and prove data-disk coverage and end-to-end notification before activation. Follow [native backup response](https://github.com/a-novel/infra/blob/master/docs/runbooks/respond-to-alerts.md#native-backup-pilot)."
  }
}
