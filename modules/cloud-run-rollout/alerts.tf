locals {
  rollout_alerts = {
    render_failed = {
      title    = "release rendering failed"
      log      = "release_render"
      match    = "jsonPayload.releaseRenderState=\"FAILED\""
      severity = "ERROR"
      guidance = "Inspect the release's rendering error before submitting another release."
    }
    rollout_failed = {
      title    = "rollout failed or stopped"
      log      = "rollout_update"
      match    = "jsonPayload.rolloutUpdateType=(\"FAILED\" OR \"CANCELLED\" OR \"HALTED\" OR \"REJECTED\")"
      severity = "ERROR"
      guidance = "Inspect the exact phase and serving traffic. A stable-phase failure occurs after promotion; cancellation does not restore prior traffic."
    }
    approval_required = {
      title    = "rollout approval required"
      log      = "rollout_update"
      match    = "jsonPayload.rolloutUpdateType=\"APPROVAL_REQUIRED\""
      severity = "WARNING"
      guidance = "Review the release and its prerequisites before an authorized operator approves this rollout."
    }
    advance_required = {
      title    = "rollout advancement required"
      log      = "rollout_update"
      match    = "jsonPayload.rolloutUpdateType=\"ADVANCE_REQUIRED\""
      severity = "WARNING"
      guidance = "Review successful candidate verification before an authorized operator advances this rollout to stable."
    }
  }
}

resource "google_monitoring_alert_policy" "rollout" {
  for_each = local.rollout_alerts

  project               = var.project_id
  display_name          = "Agora ${var.name}: ${each.value.title}"
  combiner              = "OR"
  enabled               = true
  severity              = each.value.severity
  notification_channels = sort(tolist(var.notification_channels))
  deletion_policy       = "DELETE"

  conditions {
    display_name = each.value.title

    condition_matched_log {
      filter = join("\n", [
        "logName=\"projects/${var.project_id}/logs/clouddeploy.googleapis.com%2F${each.value.log}\"",
        "resource.type=\"clouddeploy.googleapis.com/DeliveryPipeline\"",
        "resource.labels.pipeline_id=\"${var.name}\"",
        "resource.labels.location=\"${var.region}\"",
        each.value.match,
      ])
      label_extractors = merge(
        { release = "EXTRACT(jsonPayload.release)" },
        each.value.log == "rollout_update" ? { rollout = "EXTRACT(jsonPayload.rollout)" } : {},
      )
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    # Log incidents close on silence, independently of deployment recovery.
    auto_close           = "604800s"
    notification_prompts = ["OPENED"]
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Release: $${log.extracted_label.release}
      ${each.value.log == "rollout_update" ? "Rollout: $${log.extracted_label.rollout}" : ""}

      ${each.value.guidance}

      [Inspect the pipeline](https://console.cloud.google.com/deploy/delivery-pipelines/${var.region}/${var.name}?project=${var.project_id})
      and follow [the rollout runbook](https://github.com/a-novel/infra/blob/master/docs/runbooks/observe-rollout.md#native-operations-alerts).
      Inspect the matching log for its exact rollout identity. Reconcile that identity before retrying; do not replay migrations.
      Incident closure is not recovery evidence. Successful native jobs and the durable receipt still need verification.
    EOT
  }
}
