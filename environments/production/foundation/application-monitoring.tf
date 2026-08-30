# Authentication's dependency endpoint is checked every three hours by the
# existing read-only drift workflow. A native uptime check cannot run less often
# than every 15 minutes and could keep this instance-billed service continuously
# allocated, so this root owns only provider-native operational metrics.
resource "google_monitoring_alert_policy" "authentication_error_rate" {
  count = var.recovery_mode ? 0 : 1

  project      = google_project.workload.project_id
  display_name = "Agora Authentication 5xx error rate"
  combiner     = "OR"
  enabled      = true
  severity     = "ERROR"

  documentation {
    content   = "Owner: production operator. More than 10% of Authentication requests returned 5xx for five minutes. Follow [Respond to production alerts](https://github.com/a-novel/infra/blob/master/docs/runbooks/respond-to-alerts.md#authentication-5xx-rate)."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "5xx responses exceed 10%"

    condition_threshold {
      filter             = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"agora-authentication-rest\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.label.response_code_class = \"5xx\""
      denominator_filter = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"agora-authentication-rest\" AND metric.type = \"run.googleapis.com/request_count\""
      comparison         = "COMPARISON_GT"
      threshold_value    = 0.10
      duration           = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.service_name"]
      }

      denominator_aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.service_name"]
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.operations_email[0].name]
  deletion_policy       = "DELETE"
}

# One native Cloud Run metric covers every declared application job failure.
# A second condition catches a stopped rotation schedule without a controller.
resource "google_monitoring_alert_policy" "application_jobs_unhealthy" {
  count = var.recovery_mode ? 0 : 1

  project      = google_project.workload.project_id
  display_name = "Agora application jobs unhealthy"
  combiner     = "OR"
  enabled      = true
  severity     = "ERROR"

  documentation {
    content   = "Owner: production operator. An Authentication or JSON Keys job failed, or JSON Keys rotation has not completed successfully for three hours. Follow [Respond to production alerts](https://github.com/a-novel/infra/blob/master/docs/runbooks/respond-to-alerts.md#application-jobs-and-key-rotation)."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Application job execution failed"

    condition_threshold {
      filter          = "resource.type = \"cloud_run_job\" AND metric.type = \"run.googleapis.com/job/completed_execution_count\" AND metric.label.result = \"failed\" AND (resource.label.job_name = starts_with(\"agora-authentication-\") OR resource.label.job_name = starts_with(\"agora-json-keys-\"))"
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

  notification_channels = [google_monitoring_notification_channel.operations_email[0].name]
  deletion_policy       = "DELETE"
}
