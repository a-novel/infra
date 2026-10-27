locals {
  # Each service root labels its workloads' spans a_novel.workload=api or job through
  # OTEL_RESOURCE_ATTRIBUTES. A job run's duration means something else than a request's.
  workload_spans = {
    api = { title = "APIs", conditions = "${local.server_spans} a_novel.workload:api" }
    job = { title = "Jobs", conditions = "${local.server_spans} a_novel.workload:job" }
  }

  span_concerns = {
    requests = { title = "Requests", aggregate = "count()" }
    failures = { title = "Failing share", aggregate = "failure_rate()" }
    duration = { title = "Duration, p95", aggregate = "p95(span.duration)" }
  }
}

# One dashboard per concern, whatever the number of services. Each widget draws one line per
# service, and requests and job runs get a widget each.
resource "sentry_dashboard" "concern" {
  for_each = local.span_concerns

  organization = var.organization
  title        = each.value.title

  dynamic "widget" {
    for_each = keys(local.workload_spans)

    content {
      title        = "${local.workload_spans[widget.value].title}, by service"
      display_type = "line"
      interval     = "5m"
      widget_type  = "spans"
      limit        = 10

      query {
        fields     = ["project", each.value.aggregate]
        columns    = ["project"]
        aggregates = [each.value.aggregate]
        conditions = local.workload_spans[widget.value].conditions
        order_by   = "-${each.value.aggregate}"
      }

      layout {
        x     = 0
        y     = widget.key * 3
        w     = 6
        h     = 3
        min_h = 2
      }
    }
  }
}

# Error events carry no workload label, so their dashboard splits by service only.
resource "sentry_dashboard" "errors" {
  organization = var.organization
  title        = "Errors"

  widget {
    title        = "Error events, by service"
    display_type = "line"
    interval     = "5m"
    widget_type  = "error-events"
    limit        = 10

    query {
      fields     = ["project", "count()"]
      columns    = ["project"]
      aggregates = ["count()"]
      conditions = ""
      order_by   = "-count()"
    }

    layout {
      x     = 0
      y     = 0
      w     = 6
      h     = 3
      min_h = 2
    }
  }
}
