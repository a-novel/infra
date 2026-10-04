resource "google_monitoring_alert_policy" "api_error_rate" {
  count = var.zone == "public-api" ? 1 : 0

  project      = var.project_id
  display_name = "Agora ${var.service} REST 5xx error rate"
  combiner     = "OR"
  enabled      = true
  severity     = "ERROR"

  documentation {
    content   = "Owner: production operator. More than 10% of ${var.service} REST requests returned 5xx for five minutes. Inspect the service's revision logs and dependency health before changing traffic."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "5xx responses exceed 10%"

    condition_threshold {
      filter             = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"agora-${var.service}-rest\" AND resource.label.location = \"${var.region}\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.label.response_code_class = \"5xx\""
      denominator_filter = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"agora-${var.service}-rest\" AND resource.label.location = \"${var.region}\" AND metric.type = \"run.googleapis.com/request_count\""
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

  notification_channels = [google_monitoring_notification_channel.operations.name]
  deletion_policy       = "DELETE"
}
