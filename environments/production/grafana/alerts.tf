locals {
  # Alloy derives these span metrics from every server span and from each trace's root, which a
  # job's run is.
  # Each carries a_novel.outcome (the cluster root's alloy.tf): fault, transient, expected or ok.
  # The duration is a native histogram.
  calls    = "traces_span_metrics_calls_total"
  duration = "traces_span_metrics_duration_seconds"

  # Each alert links its runbook, and the journey panel that draws what it watches.
  runbook = "https://github.com/a-novel/infra/blob/master/docs/runbooks/alerts.md#grafana-alerts"

  # The kubelets' gRPC probes call each pod every few seconds, so they would drown the failures and
  # the duration of every other request.
  probes = "grpc.health.v1.Health/Check"

  # Faults are filed by hand from Discord. Each span's fault type fires while it recurs, and an error
  # type the service has not raised for a week also fires as new. Transient failures count only
  # toward the failing share, and expected refusals toward nothing.
  service_rules = { for service, alert in var.alerts : service => [
    {
      title     = "${service}: failing share"
      for       = "5m"
      dashboard = "errors"
      panel     = 5
      summary   = "{{ humanizePercentage $values.query.Value }} of its calls failed over 10 minutes, past ${format("%g", alert.failure_rate * 100)}%."
      expr      = <<-EOT
        sum(rate(${local.calls}{service_name="${service}", span_name!="${local.probes}", a_novel_outcome=~"fault|transient"}[10m]))
          / sum(rate(${local.calls}{service_name="${service}", span_name!="${local.probes}"}[10m]))
          > ${alert.failure_rate}
      EOT
    },
    {
      title     = "${service}: slow requests"
      for       = "5m"
      dashboard = "performance"
      panel     = 1
      summary   = "95% of its requests took up to {{ humanizeDuration $values.query.Value }} over 10 minutes, past ${alert.p95_seconds}s."
      expr      = <<-EOT
        histogram_quantile(0.95, sum(rate(
          ${local.duration}{service_name="${service}", a_novel_workload="api", span_name!~"${join("|", concat([local.probes], alert.latency_ignores))}"}[10m]
        ))) > ${alert.p95_seconds}
      EOT
    },
    {
      title     = "${service}: faults"
      for       = "0s"
      dashboard = "errors"
      panel     = 7
      summary   = "{{ index $labels \"span_name\" }}: {{ index $labels \"error_type\" }}, {{ humanize $values.query.Value }} in 10 minutes."
      expr      = <<-EOT
        sum by (span_name, error_type) (
          increase(${local.calls}{service_name="${service}", a_novel_outcome="fault"}[10m])
        ) > 0
      EOT
    },
    {
      title     = "${service}: new fault"
      for       = "0s"
      dashboard = "errors"
      panel     = 7
      summary   = "It raised {{ index $labels \"error_type\" }}, which it had not raised for a week."
      expr      = <<-EOT
        group by (error_type) (increase(${local.calls}{service_name="${service}", error_type!=""}[10m]) > 0)
          unless group by (error_type) (present_over_time(${local.calls}{service_name="${service}", error_type!=""}[1w] offset 10m))
      EOT
    },
  ] }

  # A CronJob alerts while its latest scheduled run has not succeeded, so a later success resolves
  # it. The wait outlasts the longest run, whose deadline is 10 minutes.
  job_rules = [
    {
      title     = "Scheduled job failing"
      dashboard = "errors"
      panel     = 4
      for       = "15m"
      summary   = "{{ $labels.namespace }}/{{ $labels.cronjob }} has not succeeded since its last scheduled run."
      expr      = <<-EOT
        kube_cronjob_status_last_schedule_time
          unless on (namespace, cronjob) kube_cronjob_status_last_successful_time >= kube_cronjob_status_last_schedule_time
      EOT
    },
    {
      title     = "Scheduled job missed"
      dashboard = "errors"
      panel     = 4
      for       = "0s"
      summary   = "{{ $labels.namespace }}/{{ $labels.cronjob }} has not started the run due {{ humanizeDuration $values.query.Value }} ago."
      expr      = "time() - kube_cronjob_next_schedule_time > 600"
    },
  ]

  # Foundation's node pool, which the autoscaler grows up to its maximum.
  node_pool = provider::terraform::decode_tfvars(file("${path.module}/../foundation/terraform.tfvars")).cluster

  # The used share of each node's CPU and memory, and of each volume. For about a minute after a
  # restart, kube-state-metrics reports each node twice. The join takes one capacity per node.
  node_usage = {
    cpu    = "rate(node_cpu_usage_seconds_total[5m]) / on (node) max by (node) (kube_node_status_capacity{resource=\"cpu\"})"
    memory = "node_memory_working_set_bytes / on (node) max by (node) (kube_node_status_capacity{resource=\"memory\"})"
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
      title     = "Volume above ${format("%.0f", var.thresholds.volume_warning * 100)}%"
      dashboard = "health"
      panel     = 15
      for       = "10m"
      summary   = "{{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is {{ humanizePercentage $values.query.Value }} full."
      expr      = "${local.volume_usage} > ${var.thresholds.volume_warning}"
    },
    {
      title     = "Volume above ${format("%.0f", var.thresholds.volume_critical * 100)}%"
      dashboard = "health"
      panel     = 15
      for       = "5m"
      summary   = "{{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is {{ humanizePercentage $values.query.Value }} full."
      expr      = "${local.volume_usage} > ${var.thresholds.volume_critical}"
    },
    {
      title     = "Node CPU above ${format("%.0f", var.thresholds.node_cpu * 100)}%"
      dashboard = "health"
      panel     = 8
      for       = "15m"
      summary   = "{{ $labels.node }} uses {{ humanizePercentage $values.query.Value }} of its CPU."
      expr      = "${local.node_usage.cpu} > ${var.thresholds.node_cpu}"
    },
    {
      title     = "Node memory above ${format("%.0f", var.thresholds.node_memory * 100)}%"
      dashboard = "health"
      panel     = 9
      for       = "10m"
      summary   = "{{ $labels.node }} uses {{ humanizePercentage $values.query.Value }} of its memory."
      expr      = "${local.node_usage.memory} > ${var.thresholds.node_memory}"
    },
    # CloudNativePG reports no lag once a replica has replayed all it received, so a replica that
    # stopped receiving reports none. The next rule catches it.
    {
      title     = "Replica lagging"
      dashboard = "health"
      panel     = 17
      for       = "5m"
      summary   = "{{ $labels.namespace }}/{{ $labels.pod }} replays WAL {{ humanizeDuration $values.query.Value }} behind its primary."
      expr      = "cnpg_pg_replication_lag > ${var.thresholds.replica_lag}"
    },
    {
      title     = "Replica not streaming"
      dashboard = "health"
      panel     = 17
      for       = "5m"
      summary   = "The {{ $labels.namespace }} database's primary streams WAL to no replica."
      expr      = "max by (namespace) (cnpg_pg_replication_streaming_replicas) < 1"
    },
    # PostgreSQL retries a failed segment until it archives, so a failed latest attempt means WAL
    # piles up on the primary's volume.
    {
      title     = "WAL archiving failing"
      dashboard = "health"
      panel     = 15
      for       = "5m"
      summary   = "{{ $labels.namespace }}/{{ $labels.pod }} fails to archive its WAL to the backup bucket."
      expr      = "cnpg_pg_stat_archiver_last_failed_time > cnpg_pg_stat_archiver_last_archived_time"
    },
    # The autoscaler absorbs spikes and transient load. Capacity that stays is a decision: raise the
    # node pool's minimum, or lower the load, in a pull request.
    {
      title     = "Cluster above its baseline"
      dashboard = "health"
      panel     = 7
      for       = "2h"
      summary   = "The cluster has run {{ $values.query.Value }} nodes for 2 hours, above its ${local.node_pool.min_nodes}-node baseline: decide whether that capacity stays."
      expr      = "count(kube_node_info) > ${local.node_pool.min_nodes}"
    },
    {
      title     = "Autoscaler at its maximum"
      dashboard = "health"
      panel     = 7
      for       = "30m"
      summary   = "The cluster runs {{ $values.query.Value }} nodes, the most its autoscaler adds."
      expr      = "count(kube_node_info) >= ${local.node_pool.max_nodes}"
    },
    # Alloy is the only collector, so every scrape stops with it, its token or its egress.
    {
      title   = "Collector silent"
      for     = "0s"
      summary = "Grafana received no scrape from Alloy for 10 minutes."
      expr    = "absent_over_time(up[10m])"
    },
  ]

  request_rules = [for resource, sum in local.requests : {
    title     = "No room for a lost node's ${sum.name} requests"
    dashboard = "health"
    panel     = resource == "cpu" ? 4 : 5
    for       = "15m"
    summary   = "The pods request {{ humanize $values.query.Value }} of ${sum.name}, more than every node but the largest holds."
    expr      = "${sum.requested} > ${sum.tolerated}"
  }]

  # Grafana Cloud's usage metrics, against what the Pro plan includes each month. Active series
  # read live, the rest accrue over the month. A replaced scrape target gives each of its series a
  # new instance, and Grafana counts the old copies for 20 more minutes, so the rules wait longer.
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
    for        = "30m"
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
      title     = "Container CPU above ${format("%.0f", var.thresholds.container_cpu * 100)}% of its request"
      dashboard = "health"
      panel     = 11
      for       = "15m"
      summary   = "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) uses {{ humanizePercentage $values.query.Value }} of the CPU it requests."
      expr      = "sum by (namespace, pod, container) (rate(container_cpu_usage_seconds_total{container!=\"\", container!=\"POD\"}[10m])) / on (namespace, pod, container) (sum by (namespace, pod, container) (kube_pod_container_resource_requests{resource=\"cpu\"}) > 0) > ${var.thresholds.container_cpu}"
    },
    {
      title     = "Container memory above ${format("%.0f", var.thresholds.container_memory * 100)}% of its limit"
      dashboard = "health"
      panel     = 12
      for       = "10m"
      summary   = "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) uses {{ humanizePercentage $values.query.Value }} of its memory limit; past it, the container is killed."
      expr      = "sum by (namespace, pod, container) (container_memory_working_set_bytes{container!=\"\", container!=\"POD\"}) / on (namespace, pod, container) (sum by (namespace, pod, container) (kube_pod_container_resource_limits{resource=\"memory\"}) > 0) > ${var.thresholds.container_memory}"
    },
    {
      title     = "Container killed for memory"
      dashboard = "health"
      panel     = 3
      for       = "0s"
      summary   = "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) restarted after running out of memory."
      expr      = "increase(kube_pod_container_status_restarts_total[10m]) > 0 and on (namespace, pod, container) kube_pod_container_status_last_terminated_reason{reason=\"OOMKilled\"} == 1"
    },
    # A pod waits when no node has room for its requests, until the autoscaler adds one.
    {
      title     = "Pod waiting to start"
      dashboard = "health"
      panel     = 2
      for       = "10m"
      summary   = "{{ $labels.namespace }}/{{ $labels.pod }} has waited 10 minutes for a node or its image."
      expr      = "max by (namespace, pod) (kube_pod_status_phase{phase=\"Pending\"}) == 1"
    },
    # Each service runs inside the cluster root's service_budgets; past it, new pods are refused.
    {
      title     = "Service above ${format("%.0f", var.thresholds.service_budget * 100)}% of its budget"
      dashboard = "health"
      panel     = 10
      for       = "10m"
      summary   = "The {{ $labels.namespace }} service uses {{ humanizePercentage $values.query.Value }} of its {{ $labels.resource }} budget."
      expr      = "max by (namespace, resource) (kube_resourcequota{type=\"used\"}) / max by (namespace, resource) (kube_resourcequota{type=\"hard\"} > 0) > ${var.thresholds.service_budget}"
    },
    {
      title     = "Workload autoscaler at its maximum"
      dashboard = "health"
      panel     = 14
      for       = "15m"
      summary   = "{{ $labels.namespace }}/{{ $labels.horizontalpodautoscaler }} runs its most replicas."
      expr      = "kube_horizontalpodautoscaler_status_current_replicas >= on (namespace, horizontalpodautoscaler) kube_horizontalpodautoscaler_spec_max_replicas"
    },
    ], [for name, database in local.databases : {
      title     = "${name}: connections above ${format("%.0f", var.thresholds.database_connections * 100)}% of the limit"
      dashboard = "health"
      panel     = 16
      for       = "10m"
      summary   = "The ${name} database holds {{ $values.query.Value }} of the ${database.max_connections} connections it admits."
      expr      = "max by (namespace) (sum by (namespace, pod) (cnpg_backends_total{namespace=\"${name}\"})) > ${database.max_connections * var.thresholds.database_connections}"
  }])

  # Promises the services' data keeps, read from their databases (the cluster root's queries/): a
  # signing key always outlives the rotation that replaces it, and GenAI deletes settled content
  # soon after its retention.
  data_rules = [
    {
      title     = "Signing keys running out"
      for       = "15m"
      dashboard = "services"
      panel     = 17
      summary   = "The newest {{ $labels.usage }} key signs for {{ humanizeDuration $values.query.Value }} more: rotation has stopped, or no key is left."
      expr      = "min by (usage) (cnpg_keys_runway_seconds) < 259200"
    },
    {
      title     = "Certificate expiring"
      for       = "1h"
      dashboard = "health"
      panel     = 18
      summary   = "{{ $labels.namespace }}/{{ $labels.name }} expires in {{ humanizeDuration $values.query.Value }}: cert-manager has stopped renewing it."
      expr      = "min by (namespace, name) (certmanager_certificate_expiration_timestamp_seconds) - time() < 1209600"
    },
    {
      title     = "GenAI keeps content past retention"
      for       = "5m"
      dashboard = "services"
      panel     = 16
      summary   = "A settled generation has been kept {{ humanizeDuration $values.query.Value }} past its retention: the purge has stopped or fallen behind."
      expr      = "max(cnpg_generations_expired_oldest_seconds) > 1800"
    },
  ]

  rule_groups = merge(local.service_rules, {
    capacity = local.capacity_rules
    data     = local.data_rules
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
      annotations = merge(
        { summary = rule.value.summary, runbook_url = local.runbook },
        can(rule.value.dashboard) ? { __dashboardUid__ = "journey-${rule.value.dashboard}", __panelId__ = tostring(rule.value.panel) } : {},
      )

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
