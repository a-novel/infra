locals {
  database_alerts = {
    cpu_sustained = {
      comparison = "COMPARISON_GT"
      duration   = "600s"
      metric     = "compute.googleapis.com/instance/cpu/utilization"
      severity   = "WARNING"
      threshold  = 0.70
      title      = "CPU above 70%"
    }
    disk_critical = {
      comparison = "COMPARISON_GT"
      duration   = "300s"
      metric     = "compute.googleapis.com/guest/disk/percent_used"
      severity   = "CRITICAL"
      threshold  = 85
      title      = "Disk above 85%"
    }
    disk_warning = {
      comparison = "COMPARISON_GT"
      duration   = "600s"
      metric     = "compute.googleapis.com/guest/disk/percent_used"
      severity   = "WARNING"
      threshold  = 70
      title      = "Disk above 70%"
    }
    memory_critical = {
      comparison = "COMPARISON_GT"
      duration   = "300s"
      metric     = "compute.googleapis.com/guest/memory/percent_used"
      severity   = "CRITICAL"
      threshold  = 85
      title      = "Memory above 85%"
    }
    memory_warning = {
      comparison = "COMPARISON_GT"
      duration   = "600s"
      metric     = "compute.googleapis.com/guest/memory/percent_used"
      severity   = "WARNING"
      threshold  = 70
      title      = "Memory above 70%"
    }
  }
}

resource "google_monitoring_alert_policy" "database_capacity" {
  for_each = var.recovery_mode ? {} : local.database_alerts

  project      = google_project.workload.project_id
  display_name = "Agora database ${each.value.title}"
  combiner     = "OR"
  enabled      = true
  severity     = each.value.severity

  documentation {
    content   = "Owner: production operator. The private PostgreSQL host crossed its reviewed ${lower(each.value.title)} threshold. Follow [Respond to production alerts](https://github.com/a-novel/infra/blob/master/docs/runbooks/respond-to-alerts.md#database-capacity) before changing capacity."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = each.value.title

    condition_threshold {
      comparison = each.value.comparison
      duration   = each.value.duration
      # Numeric VM IDs and generated-name suffixes can change during repair.
      # The fixed MIG base name selects its sole member without another
      # monitoring group or a live value baked into the policy.
      filter          = "resource.type = \"gce_instance\" AND resource.label.zone = \"${var.database_zone}\" AND metric.type = \"${each.value.metric}\" AND metric.label.instance_name = starts_with(\"agora-database-\")"
      threshold_value = each.value.threshold

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.operations_email[0].name]
  deletion_policy       = "DELETE"
}
