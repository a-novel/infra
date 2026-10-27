locals {
  # The span widgets read the same server spans as the monitors; the last one counts error events.
  dashboard_widgets = [
    { title = "Requests", widget_type = "spans", aggregate = "count()", extra = local.server_spans, x = 0, y = 0 },
    { title = "Failing share", widget_type = "spans", aggregate = "failure_rate()", extra = local.server_spans, x = 3, y = 0 },
    { title = "Duration, p95", widget_type = "spans", aggregate = "p95(span.duration)", extra = local.server_spans, x = 0, y = 2 },
    { title = "Error events", widget_type = "error-events", aggregate = "count()", extra = "", x = 3, y = 2 },
  ]
}

# One dashboard per service: its request rate, errors and duration.
resource "sentry_dashboard" "service" {
  for_each = var.projects

  organization = var.organization
  title        = each.key

  dynamic "widget" {
    for_each = local.dashboard_widgets

    content {
      title        = widget.value.title
      display_type = "line"
      interval     = "5m"
      widget_type  = widget.value.widget_type

      query {
        fields     = [widget.value.aggregate]
        aggregates = [widget.value.aggregate]
        conditions = trimspace("project:${each.key} ${widget.value.extra}")
        order_by   = ""
      }

      layout {
        x     = widget.value.x
        y     = widget.value.y
        w     = 3
        h     = 2
        min_h = 2
      }
    }
  }
}
