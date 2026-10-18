# The sweep settles the generations nobody polled. Without it, they keep their owners' concurrency
# slots and their results expire at the provider. A planned downtime answers 503 on every route, so
# 503s stay out of the count.
resource "google_monitoring_alert_policy" "sweep_failures" {
  project      = local.project_id
  display_name = "A-Novel genai sweep calls failing"
  combiner     = "OR"
  enabled      = true
  severity     = "ERROR"

  documentation {
    content   = "Owner: production operator. At least three scheduled sweep calls failed in ten minutes. Unpolled generations are not checked meanwhile. Inspect the sweep's revision logs, its database host and the provider's status."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Sweep 5xx responses other than 503"

    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"${google_cloud_run_v2_service.sweep.name}\" AND resource.label.location = \"${local.region}\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.label.response_code_class = \"5xx\" AND metric.label.response_code != \"503\""
      comparison      = "COMPARISON_GT"
      threshold_value = 2
      duration        = "60s"

      aggregations {
        alignment_period     = "600s"
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

  notification_channels = [module.runtime.notification_channel]
  deletion_policy       = "DELETE"
}
