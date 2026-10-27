locals {
  # A server span is a service's segment: the first span of a request in that service. Its
  # failures, duration and count describe the service as its callers see it.
  server_spans = "is_transaction:true"

  monitors = merge([for repository, alert in var.alerts : {
    "${repository}/failures" = {
      project   = repository
      name      = "${repository}: failing requests"
      aggregate = "failure_rate()"
      type      = "gt"
      threshold = alert.failure_rate
      window    = 600
    }
    "${repository}/latency" = {
      project   = repository
      name      = "${repository}: slow requests"
      aggregate = "p95(span.duration)"
      type      = "gt"
      threshold = alert.p95_ms
      window    = 600
    }
    # A revoked key, a closed egress rule or a broken exporter loses telemetry silently, and no
    # failure or latency monitor fires on data that never comes.
    "${repository}/silence" = {
      project   = repository
      name      = "${repository}: telemetry stopped"
      aggregate = "count()"
      type      = "lt"
      threshold = 1
      window    = alert.no_data_seconds
    }
  }]...)
}

resource "sentry_metric_monitor" "service" {
  for_each = local.monitors

  organization        = var.organization
  project             = sentry_project.service[each.value.project].slug
  name                = each.value.name
  aggregate           = each.value.aggregate
  dataset             = "events_analytics_platform"
  event_types         = ["trace_item_span"]
  query               = local.server_spans
  time_window_seconds = each.value.window

  owner = {
    team_id = data.sentry_team.owner.internal_id
  }

  # The issue opens at high priority past the threshold, and resolves once back within it.
  condition_group = {
    conditions = [
      { type = each.value.type, comparison = each.value.threshold, condition_result = 75 },
      { type = each.value.type == "gt" ? "lte" : "gte", comparison = each.value.threshold, condition_result = 0 },
    ]
  }

  issue_detection = {
    type = "static"
  }
}

data "sentry_organization_integration" "discord" {
  organization = var.organization
  provider_key = "discord"
  name         = var.discord.server
}

# One alert posts every monitor's issue to Discord when it opens, comes back or resolves.
resource "sentry_alert" "discord" {
  organization      = var.organization
  name              = "Service health to Discord"
  monitor_ids       = [for monitor in sentry_metric_monitor.service : monitor.id]
  frequency_minutes = 30

  trigger_conditions = [
    { first_seen_event = {} },
    { regression_event = {} },
    { issue_resolved_trigger = {} },
  ]

  action_filters = [
    {
      logic_type = "all"
      actions = [
        {
          discord = {
            integration_id = data.sentry_organization_integration.discord.id
            channel_id     = var.discord.channel_id
            tags           = "environment"
          }
        },
      ]
    },
  ]
}
