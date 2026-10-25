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

# GenAI's database host logs, every five minutes, how long the oldest expired generation has waited
# for the retention purge. The purge takes the oldest first, every 10 seconds, so the wait stays near
# zero.
resource "google_logging_metric" "oldest_expired_generation" {
  project     = local.project_id
  name        = "a-novel-genai-oldest-expired-generation"
  description = "Seconds the oldest expired generation has waited for the retention purge, as GenAI's database host reads them."
  filter = join(" AND ", [
    "resource.type=\"gce_instance\"",
    "log_id(\"cos_system\")",
    "jsonPayload._HOSTNAME=~\"^agora-database-genai-\"",
    "jsonPayload._SYSTEMD_UNIT=\"a-novel-database-probe.service\"",
    "jsonPayload.MESSAGE=~\"^oldest_expired_seconds=[0-9]+$\"",
  ])
  value_extractor = "REGEXP_EXTRACT(jsonPayload.MESSAGE, \"oldest_expired_seconds=([0-9]+)\")"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "s"
  }

  # The alert's threshold is a bucket bound, so the bucketed reading crosses it when the wait does.
  bucket_options {
    explicit_buckets {
      bounds = [60, 600, 1800, 3600, 21600]
    }
  }
}

# Past 30 minutes, either the purge stopped, or more than 30 minutes of its fastest pace, about
# 11 GiB, waits ahead of that generation. A planned downtime stops the services, not the purge.
resource "google_monitoring_alert_policy" "purge_backlog" {
  project      = local.project_id
  display_name = "A-Novel genai purge falling behind"
  combiner     = "OR"
  enabled      = true
  severity     = "ERROR"

  documentation {
    content   = "Owner: production operator. An expired generation waited over 30 minutes for the retention purge, or GenAI's database host stopped reporting the wait. Expired content fills the data disk until the purge catches up. Follow [the alert runbook](https://github.com/a-novel/infra/blob/master/docs/runbooks/alerts.md#genai-purge-falling-behind)."
    mime_type = "text/markdown"
  }

  # Each 10-minute window holds at least one reading. A replaced host reports under a new instance
  # ID, so both conditions read the highest wait of any.
  conditions {
    display_name = "Oldest expired generation waited over 30 minutes"

    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.oldest_expired_generation.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1800
      duration        = "0s"

      aggregations {
        alignment_period     = "600s"
        per_series_aligner   = "ALIGN_PERCENTILE_99"
        cross_series_reducer = "REDUCE_MAX"
      }

      trigger {
        count = 1
      }
    }
  }

  conditions {
    display_name = "No purge reading for 30 minutes"

    condition_absent {
      filter   = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.oldest_expired_generation.name}\""
      duration = "1800s"

      aggregations {
        alignment_period     = "600s"
        per_series_aligner   = "ALIGN_PERCENTILE_99"
        cross_series_reducer = "REDUCE_MAX"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [module.runtime.notification_channel]
  deletion_policy       = "DELETE"
}
