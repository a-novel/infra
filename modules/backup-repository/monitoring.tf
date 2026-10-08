# Backup jobs run on the database host, so every signal is scoped to that VM.
data "google_compute_instance_group" "database" {
  project = var.project_id
  zone    = var.database.zone
  name    = var.database.group

  lifecycle {
    postcondition {
      condition     = length(self.instances) == 1
      error_message = "Backup monitoring requires exactly one database host."
    }
  }
}

data "google_compute_instance" "database" {
  self_link = one(data.google_compute_instance_group.database.instances)
}

locals {
  log_scope = join(" AND ", [
    "resource.type=\"gce_instance\"",
    "resource.labels.project_id=\"${var.project_id}\"",
    "resource.labels.instance_id=\"${data.google_compute_instance.database.instance_id}\"",
  ])
  metric_scope    = "monitored_resource=\"gce_instance\", project_id=\"${var.project_id}\", instance_id=\"${data.google_compute_instance.database.instance_id}\""
  data_disk_scope = "${local.metric_scope}, fs_type=\"ext4\", mount_option=~\"(^|.*,)noatime(,.*|$)\""

  freshness = {
    full = {
      jobs = "agora-backup-full", window = "24h", title = "Sunday full backup missed its 04:00 UTC deadline"
      gate = " and (day_of_week() == 0) and (hour() >= 4)"
    }
    backup = { jobs = "agora-backup-(full|diff)", window = "24h45m", title = "No backup success in 24 hours 45 minutes", gate = "" }
    check  = { jobs = "agora-backup-check", window = "3h", title = "No archive check success in three hours", gate = "" }
  }
  health_rules = merge({
    for name, rule in local.freshness : name => {
      title = rule.title
      query = "((sum(increase({\"logging.googleapis.com/user/${google_logging_metric.backup_success.name}\", ${local.metric_scope}, job=~\"${rule.jobs}\"}[${rule.window}])) or vector(0)) < 1)${rule.gate}"
    }
    }, {
    disk = {
      title = "Database disk above 85%, or disk telemetry missing for one hour"
      query = join(" or ", [
        "100 * sum by (device_name) ({\"compute.googleapis.com/guest/disk/bytes_used\", ${local.data_disk_scope}, state=\"used\"}) / sum by (device_name) ({\"compute.googleapis.com/guest/disk/bytes_used\", ${local.data_disk_scope}, state=~\"used|free\"}) > 85",
        "absent_over_time({\"compute.googleapis.com/guest/disk/bytes_used\", ${local.data_disk_scope}, state=\"used\"}[1h])",
        "absent_over_time({\"compute.googleapis.com/guest/disk/bytes_used\", ${local.data_disk_scope}, state=\"free\"}[1h])",
      ])
    }
  })
}

resource "google_logging_metric" "backup_success" {
  project     = var.project_id
  name        = "agora_${var.service}_backup_success"
  description = "Completed native commands, not proof of restorable backup dependencies."
  filter = join(" AND ", [
    local.log_scope,
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

resource "google_monitoring_alert_policy" "backup_failure" {
  project               = var.project_id
  display_name          = "Agora ${var.service} native backup failed"
  combiner              = "OR"
  enabled               = true
  severity              = "ERROR"
  notification_channels = [var.notification_channel]
  deletion_policy       = "DELETE"

  conditions {
    display_name = "pgBackRest, WAL archiving or its systemd worker reported an error"
    condition_matched_log {
      filter = "${local.log_scope} AND (${join(" OR ", [
        "(log_id(\"cos_containers\") AND jsonPayload.message=~\"(ERROR: \\\\[[0-9]+\\\\]:|archive command failed)\")",
        "(log_id(\"cos_containers\") AND jsonPayload.\"cos.googleapis.com/container_name\"=\"agora-backup-verify\" AND jsonPayload.message=~\"(?m)^ *(status: error|no archives or backups exist in the repo) *$\")",
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
    content   = "Read the worker's journal on the database host. Verify can exit zero with an error report, so read its output. Never disable WAL archiving or delete WAL. Follow [the alert runbook](https://github.com/a-novel/infra/blob/master/docs/runbooks/alerts.md#backups)."
  }
}

resource "google_monitoring_alert_policy" "backup_health" {
  for_each = local.health_rules

  project               = var.project_id
  display_name          = "Agora ${var.service}: ${each.value.title}"
  combiner              = "OR"
  enabled               = true
  severity              = "ERROR"
  notification_channels = [var.notification_channel]
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
    content   = "No recent success means a stopped host, a failing job or missing logs. Disk pressure can come from WAL kept after failed archiving. Follow [the alert runbook](https://github.com/a-novel/infra/blob/master/docs/runbooks/alerts.md#backups)."
  }
}
