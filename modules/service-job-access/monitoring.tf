locals {
  execution_metric = join(" AND ", [
    "resource.type=\"cloud_run_job\"",
    "resource.labels.project_id=\"${var.runtime.project_id}\"",
    "resource.labels.location=\"${var.runtime.region}\"",
    "metric.type=\"run.googleapis.com/job/completed_execution_count\"",
  ])
  rotation_success = "${local.execution_metric} AND resource.labels.job_name=\"agora-json-keys-rotatekeys\" AND metric.labels.result=\"succeeded\""
}

resource "google_monitoring_alert_policy" "jobs" {
  project               = var.runtime.project_id
  display_name          = "Agora ${var.runtime.service} application jobs unhealthy"
  combiner              = "OR"
  enabled               = true
  severity              = "ERROR"
  notification_channels = sort(tolist(var.runtime.notification_channels))
  deletion_policy       = "DELETE"

  conditions {
    display_name = "Application job execution unsuccessful"
    condition_threshold {
      filter          = "${local.execution_metric} AND metric.labels.result!=\"succeeded\" AND (${join(" OR ", [for job in sort(tolist(local.job_names)) : "resource.labels.job_name=\"${job}\""])})"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
      trigger { count = 1 }
    }
  }

  dynamic "conditions" {
    for_each = var.runtime.service == "json-keys" ? [1] : []
    content {
      display_name = "No successful rotation in three hours"
      condition_threshold {
        filter                  = local.rotation_success
        comparison              = "COMPARISON_LT"
        threshold_value         = 1
        duration                = "60s"
        evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
        aggregations {
          alignment_period   = "10800s"
          per_series_aligner = "ALIGN_SUM"
        }
        trigger { count = 1 }
      }
    }
  }

  # Zero-valued samples and absent samples need different native conditions.
  dynamic "conditions" {
    for_each = var.runtime.service == "json-keys" ? [1] : []
    content {
      display_name = "Rotation success telemetry absent for three hours"
      condition_absent {
        filter   = local.rotation_success
        duration = "10800s"
        aggregations {
          alignment_period   = "300s"
          per_series_aligner = "ALIGN_SUM"
        }
        trigger { count = 1 }
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Owner: the operations channel for ${var.runtime.service} in ${var.runtime.project_id}/${var.runtime.region}.
      Inspect the exact job's native executions before retrying; scheduler acceptance is not application completion.
      A quiet or closed incident is not proof of recovery. Rotation absence monitoring requires observed metric history.
      Follow [service job response](https://github.com/a-novel/infra/blob/master/docs/runbooks/respond-to-alerts.md#service-owned-job-pilot).
      Never replay an uncertain migration or resume rotation as unconditional failure cleanup.
    EOT
  }
}
