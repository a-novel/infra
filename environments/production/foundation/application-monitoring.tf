# One native Cloud Run metric covers every declared application job failure.
# A second condition catches a stopped rotation schedule without a controller.
resource "google_monitoring_alert_policy" "application_jobs_unhealthy" {
  project      = google_project.workload.project_id
  display_name = "A-Novel application jobs unhealthy"
  combiner     = "OR"
  enabled      = true
  severity     = "ERROR"

  documentation {
    content   = "Owner: production operator. An Authentication, JSON Keys or GenAI job failed, or JSON Keys rotation has not completed successfully for three hours. Follow [the alert runbook](https://github.com/a-novel/infra/blob/master/docs/runbooks/alerts.md#application-jobs-and-key-rotation)."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Application job execution failed"

    condition_threshold {
      filter          = "resource.type = \"cloud_run_job\" AND metric.type = \"run.googleapis.com/job/completed_execution_count\" AND metric.label.result = \"failed\" AND (resource.label.job_name = starts_with(\"agora-authentication-\") OR resource.label.job_name = starts_with(\"agora-json-keys-\") OR resource.label.job_name = starts_with(\"agora-genai-\"))"
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
    display_name = "JSON Keys rotation success missing"

    # Rotation is evaluated hourly and Cloud Run metrics can take two minutes
    # to appear. Three hours catches two missed evaluations without alerting on
    # one delayed schedule. The first protected release seeds this time series.
    condition_absent {
      filter   = "resource.type = \"cloud_run_job\" AND metric.type = \"run.googleapis.com/job/completed_execution_count\" AND metric.label.result = \"succeeded\" AND resource.label.job_name = \"agora-json-keys-rotatekeys\""
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

  notification_channels = [google_monitoring_notification_channel.operations_email.name]
  deletion_policy       = "PREVENT"
  lifecycle {
    prevent_destroy = true
  }
}
