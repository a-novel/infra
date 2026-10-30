locals {
  # Each service root labels its workloads' spans a_novel.workload=api or job. A job run's duration
  # means something else than a request's.
  workloads = {
    api = { title = "APIs", spans = "a_novel_workload=\"api\", span_name!=\"${local.probes}\"" }
    job = { title = "Jobs", spans = "a_novel_workload=\"job\"" }
  }

  # Each workload's calls, failing share and duration, one line per service.
  span_panels = flatten([for workload in values(local.workloads) : [
    {
      title   = "${workload.title}: calls per second"
      unit    = "ops"
      targets = { "{{service_name}}" = "sum by (service_name) (rate(${local.calls}{${workload.spans}}[$__rate_interval]))" }
    },
    {
      title   = "${workload.title}: failing share"
      unit    = "percentunit"
      targets = { "{{service_name}}" = "sum by (service_name) (rate(${local.calls}{${workload.spans}, status_code=\"STATUS_CODE_ERROR\"}[$__rate_interval])) / sum by (service_name) (rate(${local.calls}{${workload.spans}}[$__rate_interval]))" }
    },
    {
      title   = "${workload.title}: duration, p95"
      unit    = "s"
      targets = { "{{service_name}}" = "histogram_quantile(0.95, sum by (service_name, le) (rate(${local.duration}{${workload.spans}}[$__rate_interval])))" }
    },
  ]])

  # Each panel draws one line per target and legend entry, three panels to a row.
  dashboards = {
    services = {
      title = "Services"
      panels = concat(local.span_panels, [{
        title   = "Faults by type"
        unit    = "short"
        targets = { "{{service_name}}: {{span_name}}, {{error_type}}" = "sum by (service_name, span_name, error_type) (increase(${local.calls}{status_code=\"STATUS_CODE_ERROR\"}[$__rate_interval])) > 0" }
      }])
    }

    cluster = {
      title = "Cluster"
      panels = [
        {
          title   = "Nodes"
          unit    = "short"
          targets = { "nodes" = "count(kube_node_info)", "autoscaler maximum" = "vector(${local.node_pool.max_nodes})" }
        },
        {
          title   = "CPU by node"
          unit    = "percentunit"
          targets = { "{{node}}" = local.node_usage.cpu }
        },
        {
          title   = "Memory by node"
          unit    = "percentunit"
          targets = { "{{node}}" = local.node_usage.memory }
        },
        {
          title   = "CPU requests"
          unit    = "short"
          targets = { "requested" = local.requests.cpu.requested, "every node but the largest" = local.requests.cpu.tolerated }
        },
        {
          title   = "Memory requests"
          unit    = "bytes"
          targets = { "requested" = local.requests.memory.requested, "every node but the largest" = local.requests.memory.tolerated }
        },
        {
          title   = "Volumes"
          unit    = "percentunit"
          targets = { "{{namespace}}/{{persistentvolumeclaim}}" = local.volume_usage }
        },
        {
          title   = "Replica lag"
          unit    = "s"
          targets = { "{{namespace}}/{{pod}}" = "cnpg_pg_replication_lag" }
        },
        {
          title   = "Container restarts"
          unit    = "short"
          targets = { "{{namespace}}/{{pod}}" = "sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[$__rate_interval])) > 0" }
        },
        {
          title   = "Since each CronJob's last success"
          unit    = "s"
          targets = { "{{namespace}}/{{cronjob}}" = "time() - kube_cronjob_status_last_successful_time" }
        },
      ]
    }
  }

  # CloudNativePG's dashboard, byte for byte as this release of cloudnative-pg/grafana-dashboards
  # ships it (charts/cluster/grafana-dashboard.json). An update replaces the file and its digest.
  cloudnative_pg = {
    release = "cluster-v0.0.5"
    sha256  = "676b10ae3a8850108d484e4491739207b2ad1ebca44300472168d81a8788e4fb"
    model   = jsondecode(file("${path.module}/dashboards/cloudnative-pg.json"))
  }

  # The dashboard reads the stack's metrics, and its Cluster from the instances' pod names: the
  # k8s-monitoring chart gives the label cluster to the Kubernetes cluster's name.
  cloudnative_pg_variables = {
    DS_PROMETHEUS = { current = { text = "grafanacloud-anovel-prom", value = local.metrics } }
    cluster       = { regex = "/pod=\"(?<text>[^\"]+)-[0-9]+\"/g" }
  }
}

resource "grafana_dashboard" "overview" {
  for_each = local.dashboards

  folder = grafana_folder.production.uid
  config_json = jsonencode({
    uid           = each.key
    title         = each.value.title
    schemaVersion = 41
    time          = { from = "now-24h", to = "now" }
    refresh       = "1m"
    panels = [for index, panel in each.value.panels : {
      id          = index + 1
      type        = "timeseries"
      title       = panel.title
      gridPos     = { x = index % 3 * 8, y = floor(index / 3) * 8, w = 8, h = 8 }
      datasource  = { type = "prometheus", uid = local.metrics }
      fieldConfig = { defaults = { unit = panel.unit }, overrides = [] }
      targets = [for position, legend in keys(panel.targets) : {
        refId        = ["A", "B"][position]
        expr         = panel.targets[legend]
        legendFormat = legend
      }]
    }]
  })
}

resource "grafana_dashboard" "cloudnative_pg" {
  folder = grafana_folder.production.uid
  config_json = jsonencode(merge(local.cloudnative_pg.model, {
    description = "CloudNativePG's dashboard, from cloudnative-pg/grafana-dashboards ${local.cloudnative_pg.release}."
    templating = { list = [for variable in local.cloudnative_pg.model.templating.list :
      merge(variable, try(local.cloudnative_pg_variables[variable.name], {}))
    ] }
  }))
}
