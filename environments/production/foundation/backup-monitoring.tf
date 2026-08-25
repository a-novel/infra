# Backup, restore, and freshness/storage checks all surface through the native
# Cloud Run failed-execution metric, avoiding another controller or log parser.
resource "google_monitoring_alert_policy" "postgres_recovery_job_failure" {
  project      = google_project.workload.project_id
  display_name = "Agora PostgreSQL recovery job failed"
  combiner     = "OR"
  enabled      = true
  severity     = "CRITICAL"

  documentation {
    content   = "A PostgreSQL backup, restore drill, or recovery monitor failed. Follow the PostgreSQL backup and restore runbook before acknowledging the alert."
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

  notification_channels = [google_monitoring_notification_channel.cost_email.name]
  deletion_policy       = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }
}
