# Native completion metrics detect both failed recovery executions and a
# stopped hourly monitor without another controller, custom metric, or log parser.
resource "google_monitoring_alert_policy" "postgres_recovery_job_failure" {
  project      = google_project.workload.project_id
  display_name = "Agora PostgreSQL recovery jobs unhealthy"
  combiner     = "OR"
  enabled      = true
  severity     = "CRITICAL"

  documentation {
    content   = "A PostgreSQL backup, restore drill, or recovery monitor failed, or the hourly monitor has not completed for three hours. Follow the PostgreSQL backup and restore runbook before acknowledging the alert."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Failed PostgreSQL recovery execution"

    condition_threshold {
      filter          = "resource.type = \"cloud_run_job\" AND metric.type = \"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result = \"failed\" AND resource.labels.job_name = starts_with(\"agora-postgres-\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_DELTA"
      }

      trigger {
        count = 1
      }
    }
  }

  conditions {
    display_name = "PostgreSQL recovery monitor missing"

    # Three hours covers the hourly cadence plus Cloud Run metric visibility
    # delay while still alerting comfortably inside the six-hour RPO.
    condition_absent {
      filter   = "resource.type = \"cloud_run_job\" AND metric.type = \"run.googleapis.com/job/completed_execution_count\" AND resource.labels.job_name = \"agora-postgres-backup-monitor\""
      duration = "10800s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_DELTA"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.cost_email.name]
  deletion_policy       = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }
}
