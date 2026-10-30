locals {
  # Alloy derives these span metrics from every server span and from each trace's root, which a
  # job's run is.
  calls    = "traces_span_metrics_calls_total"
  duration = "traces_span_metrics_duration_seconds_bucket"

  # The kubelets' gRPC probes call each pod every few seconds, so they would drown the failures and
  # the duration of every other request.
  probes = "grpc.health.v1.Health/Check"

  # Faults are filed by hand from Discord. Each span's fault type fires while it recurs, and an error
  # type the service has not raised for a week also fires as new.
  service_rules = { for service, alert in var.alerts : service => [
    {
      title   = "${service}: failing share"
      for     = "5m"
      summary = "{{ humanizePercentage $values.query.Value }} of ${service}'s requests and job runs failed over 10 minutes."
      expr    = <<-EOT
        sum(rate(${local.calls}{service_name="${service}", span_name!="${local.probes}", status_code="STATUS_CODE_ERROR"}[10m]))
          / sum(rate(${local.calls}{service_name="${service}", span_name!="${local.probes}"}[10m]))
          > ${alert.failure_rate}
      EOT
    },
    {
      title   = "${service}: slow requests"
      for     = "5m"
      summary = "${service}'s requests took {{ humanizeDuration $values.query.Value }} at the 95th percentile over 10 minutes."
      expr    = <<-EOT
        histogram_quantile(0.95, sum by (le) (rate(
          ${local.duration}{service_name="${service}", a_novel_workload="api", span_name!~"${join("|", concat([local.probes], alert.latency_ignores))}"}[10m]
        ))) > ${alert.p95_seconds}
      EOT
    },
    {
      title   = "${service}: faults"
      for     = "0s"
      summary = "{{ index $labels \"span_name\" }} failed in the last 10 minutes: {{ index $labels \"error_type\" }}."
      expr    = <<-EOT
        sum by (span_name, error_type) (
          increase(${local.calls}{service_name="${service}", status_code="STATUS_CODE_ERROR"}[10m])
        ) > 0
      EOT
    },
    {
      title   = "${service}: new fault"
      for     = "0s"
      summary = "${service} raised {{ index $labels \"error_type\" }}, which it had not raised for a week."
      expr    = <<-EOT
        group by (error_type) (increase(${local.calls}{service_name="${service}", error_type!=""}[10m]) > 0)
          unless group by (error_type) (present_over_time(${local.calls}{service_name="${service}", error_type!=""}[1w] offset 10m))
      EOT
    },
  ] }

  # A CronJob alerts while its latest scheduled run has not succeeded, so a later success resolves
  # it. The wait outlasts the longest run, whose deadline is 10 minutes.
  job_rules = [
    {
      title   = "Scheduled job failing"
      for     = "15m"
      summary = "{{ $labels.namespace }}/{{ $labels.cronjob }} has not succeeded since its last scheduled run."
      expr    = <<-EOT
        kube_cronjob_status_last_schedule_time
          unless on (namespace, cronjob) kube_cronjob_status_last_successful_time >= kube_cronjob_status_last_schedule_time
      EOT
    },
    {
      title   = "Scheduled job missed"
      for     = "0s"
      summary = "{{ $labels.namespace }}/{{ $labels.cronjob }} has not started the run due {{ humanizeDuration $values.query.Value }} ago."
      expr    = "time() - kube_cronjob_next_schedule_time > 600"
    },
  ]

  # Foundation's node pool, which the autoscaler grows up to its maximum.
  node_pool = provider::terraform::decode_tfvars(file("${path.module}/../foundation/terraform.tfvars")).cluster

  # The used share of each node's CPU and memory, and of each volume.
  node_usage = {
    cpu    = "rate(node_cpu_usage_seconds_total[5m]) / on (node) kube_node_status_capacity{resource=\"cpu\"}"
    memory = "node_memory_working_set_bytes / on (node) kube_node_status_capacity{resource=\"memory\"}"
  }
  volume_usage = "kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes"

  # When a node goes, its pods move to the others, and each database recreates its lost instance
  # there. So the running and pending pods' requests must fit every node but the largest.
  requests = { for resource, name in { cpu = "CPU", memory = "memory" } : resource => {
    name      = name
    requested = "sum(kube_pod_container_resource_requests{resource=\"${resource}\"} * on (namespace, pod) group_left () max by (namespace, pod) (kube_pod_status_phase{phase=~\"Pending|Running\"}))"
    tolerated = "sum(kube_node_status_allocatable{resource=\"${resource}\"}) - max(kube_node_status_allocatable{resource=\"${resource}\"})"
  } }

  platform_rules = [
    {
      title   = "Volume above ${format("%.0f", var.thresholds.volume_warning * 100)}%"
      for     = "10m"
      summary = "{{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is {{ humanizePercentage $values.query.Value }} full."
      expr    = "${local.volume_usage} > ${var.thresholds.volume_warning}"
    },
    {
      title   = "Volume above ${format("%.0f", var.thresholds.volume_critical * 100)}%"
      for     = "5m"
      summary = "{{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is {{ humanizePercentage $values.query.Value }} full."
      expr    = "${local.volume_usage} > ${var.thresholds.volume_critical}"
    },
    {
      title   = "Node CPU above ${format("%.0f", var.thresholds.node_cpu * 100)}%"
      for     = "15m"
      summary = "{{ $labels.node }} uses {{ humanizePercentage $values.query.Value }} of its CPU."
      expr    = "${local.node_usage.cpu} > ${var.thresholds.node_cpu}"
    },
    {
      title   = "Node memory above ${format("%.0f", var.thresholds.node_memory * 100)}%"
      for     = "10m"
      summary = "{{ $labels.node }} uses {{ humanizePercentage $values.query.Value }} of its memory."
      expr    = "${local.node_usage.memory} > ${var.thresholds.node_memory}"
    },
    # CloudNativePG reports no lag once a replica has replayed all it received, so a replica that
    # stopped receiving reports none. The next rule catches it.
    {
      title   = "Replica lagging"
      for     = "5m"
      summary = "{{ $labels.namespace }}/{{ $labels.pod }} replays WAL {{ humanizeDuration $values.query.Value }} behind its primary."
      expr    = "cnpg_pg_replication_lag > ${var.thresholds.replica_lag}"
    },
    {
      title   = "Replica not streaming"
      for     = "5m"
      summary = "The {{ $labels.namespace }} database's primary streams WAL to no replica."
      expr    = "max by (namespace) (cnpg_pg_replication_streaming_replicas) < 1"
    },
    # PostgreSQL retries a failed segment until it archives, so a failed latest attempt means WAL
    # piles up on the primary's volume.
    {
      title   = "WAL archiving failing"
      for     = "5m"
      summary = "{{ $labels.namespace }}/{{ $labels.pod }} fails to archive its WAL to the backup bucket."
      expr    = "cnpg_pg_stat_archiver_last_failed_time > cnpg_pg_stat_archiver_last_archived_time"
    },
    {
      title   = "Autoscaler at its maximum"
      for     = "30m"
      summary = "The cluster runs {{ $values.query.Value }} nodes, the most its autoscaler adds."
      expr    = "count(kube_node_info) >= ${local.node_pool.max_nodes}"
    },
    # Alloy is the only collector, so every scrape stops with it, its token or its egress.
    {
      title   = "Collector silent"
      for     = "0s"
      summary = "Grafana received no scrape from Alloy for 10 minutes."
      expr    = "absent_over_time(up[10m])"
    },
  ]

  request_rules = [for sum in values(local.requests) : {
    title   = "No room for a lost node's ${sum.name} requests"
    for     = "15m"
    summary = "The pods request {{ humanize $values.query.Value }} of ${sum.name}, more than every node but the largest holds."
    expr    = "${sum.requested} > ${sum.tolerated}"
  }]

  # Grafana Cloud's usage metrics, against what the Pro plan includes each month. Active series
  # read live, the rest accrue over the month.
  allowances = {
    "metrics series"                  = { used = "grafanacloud_instance_active_series", included = "grafanacloud_org_metrics_included_series" }
    "logs"                            = { used = "grafanacloud_org_logs_usage", included = "grafanacloud_org_logs_included_usage" }
    "traces"                          = { used = "grafanacloud_org_traces_usage", included = "grafanacloud_org_traces_included_usage" }
    "Frontend Observability sessions" = { used = "grafanacloud_org_fe_o11y_billable_sessions", included = "grafanacloud_org_fe_o11y_included_sessions" }
    "Kubernetes hosts"                = { used = "grafanacloud_org_infra_o11y_billable_host_hours", included = "grafanacloud_org_infra_o11y_included_host_hours" }
    "Kubernetes containers"           = { used = "grafanacloud_org_infra_o11y_billable_container_hours", included = "grafanacloud_org_infra_o11y_included_container_hours" }
    "Application Observability hosts" = { used = "grafanacloud_org_app_o11y_billable_host_hours", included = "grafanacloud_org_app_o11y_included_host_hours" }
  }

  usage_rules = [for allowance, metric in local.allowances : {
    title      = "Usage: ${allowance} above ${format("%.0f", var.thresholds.usage * 100)}% of the plan"
    for        = "0s"
    datasource = local.usage
    summary    = "The month's ${allowance} reached {{ humanizePercentage $values.query.Value }} of what the plan includes."
    expr       = "sum(${metric.used}) / sum(${metric.included}) > ${var.thresholds.usage}"
  }]

  # The overage sums every allowance's cost beyond the plan, in US dollars.
  overage_rule = {
    title      = "Usage: overage"
    for        = "0s"
    datasource = local.usage
    summary    = "This month's usage already costs {{ $values.query.Value }} USD beyond the plan."
    expr       = "sum(grafanacloud_org_total_overage) > 0"
  }

  # The cluster's databases, with the connections each admits.
  databases = provider::terraform::decode_tfvars(file("${path.module}/../cluster/terraform.tfvars")).databases

  # Each warns while a resource still has room, so a request, a limit or the node pool can rise
  # before work queues or fails. A container without a request or limit has no ceiling to approach.
  capacity_rules = concat([
    {
      title   = "Container CPU above ${format("%.0f", var.thresholds.container_cpu * 100)}% of its request"
      for     = "15m"
      summary = "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) uses {{ humanizePercentage $values.query.Value }} of the CPU it requests."
      expr    = "sum by (namespace, pod, container) (rate(container_cpu_usage_seconds_total{container!=\"\", container!=\"POD\"}[10m])) / on (namespace, pod, container) (sum by (namespace, pod, container) (kube_pod_container_resource_requests{resource=\"cpu\"}) > 0) > ${var.thresholds.container_cpu}"
    },
    {
      title   = "Container memory above ${format("%.0f", var.thresholds.container_memory * 100)}% of its limit"
      for     = "10m"
      summary = "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) uses {{ humanizePercentage $values.query.Value }} of its memory limit; past it, the container is killed."
      expr    = "sum by (namespace, pod, container) (container_memory_working_set_bytes{container!=\"\", container!=\"POD\"}) / on (namespace, pod, container) (sum by (namespace, pod, container) (kube_pod_container_resource_limits{resource=\"memory\"}) > 0) > ${var.thresholds.container_memory}"
    },
    {
      title   = "Container killed for memory"
      for     = "0s"
      summary = "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) restarted after running out of memory."
      expr    = "increase(kube_pod_container_status_restarts_total[10m]) > 0 and on (namespace, pod, container) kube_pod_container_status_last_terminated_reason{reason=\"OOMKilled\"} == 1"
    },
    # A pod waits when no node has room for its requests, until the autoscaler adds one.
    {
      title   = "Pod waiting to start"
      for     = "10m"
      summary = "{{ $labels.namespace }}/{{ $labels.pod }} has waited 10 minutes for a node or its image."
      expr    = "max by (namespace, pod) (kube_pod_status_phase{phase=\"Pending\"}) == 1"
    },
    {
      title   = "Workload autoscaler at its maximum"
      for     = "15m"
      summary = "{{ $labels.namespace }}/{{ $labels.horizontalpodautoscaler }} runs its most replicas."
      expr    = "kube_horizontalpodautoscaler_status_current_replicas >= on (namespace, horizontalpodautoscaler) kube_horizontalpodautoscaler_spec_max_replicas"
    },
    ], [for name, database in local.databases : {
      title   = "${name}: connections above ${format("%.0f", var.thresholds.database_connections * 100)}% of the limit"
      for     = "10m"
      summary = "The ${name} database holds {{ $values.query.Value }} of the ${database.max_connections} connections it admits."
      expr    = "max by (namespace) (sum by (namespace, pod) (cnpg_backends_total{namespace=\"${name}\"})) > ${database.max_connections * var.thresholds.database_connections}"
  }])

  rule_groups = merge(local.service_rules, {
    capacity = local.capacity_rules
    jobs     = local.job_rules
    platform = concat(local.platform_rules, local.request_rules)
    usage    = concat(local.usage_rules, [local.overage_rule])
  })
}

resource "grafana_rule_group" "alerts" {
  for_each = local.rule_groups

  name             = each.key
  folder_uid       = grafana_folder.production.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = each.value

    content {
      name      = rule.value.title
      for       = rule.value.for
      condition = "firing"
      # A query that returns nothing is healthy, as in a Prometheus rule.
      no_data_state  = "OK"
      exec_err_state = "Error"
      annotations    = { summary = rule.value.summary }

      data {
        ref_id         = "query"
        datasource_uid = lookup(rule.value, "datasource", local.metrics)
        model          = jsonencode({ refId = "query", expr = rule.value.expr, instant = true })

        relative_time_range {
          from = 600
          to   = 0
        }
      }

      # Grafana's own reading of a Prometheus rule: every series the query returns fires.
      data {
        ref_id         = "firing"
        datasource_uid = "__expr__"
        model          = jsonencode({ refId = "firing", type = "math", expression = "is_number($query) || is_nan($query) || is_inf($query)" })

        relative_time_range {
          from = 0
          to   = 0
        }
      }
    }
  }
}
