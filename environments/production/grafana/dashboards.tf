locals {
  # The daily journey, read in this order: what needs action now, then the cluster's health, then
  # performance, then each service's own numbers. Each dashboard is Grafana's own JSON under
  # dashboards/, so a panel changed in the UI exports back as is. The first three hold one view;
  # Services holds a tab per service, which only the v2 schema has.
  journey = {
    errors      = { title = "1. Errors", from = "now-7d", refresh = "1m" }
    health      = { title = "2. Health", from = "now-24h", refresh = "1m" }
    performance = { title = "3. Performance", from = "now-7d", refresh = "5m" }
  }

  # Every journey dashboard links the others, then the drilldown apps, keeping the time range. Health
  # also links the CloudNativePG dashboard.
  journey_links = [
    { type = "dashboards", title = "Journey", tags = ["journey"], asDropdown = false, keepTime = true, includeVars = false, targetBlank = false, icon = "external link", tooltip = "" },
    { type = "link", title = "Traces", url = "/a/grafana-exploretraces-app/explore", tags = [], asDropdown = false, keepTime = true, includeVars = false, targetBlank = false, icon = "external link", tooltip = "" },
    { type = "link", title = "Logs", url = "/a/grafana-lokiexplore-app/explore", tags = [], asDropdown = false, keepTime = true, includeVars = false, targetBlank = false, icon = "external link", tooltip = "" },
  ]
  database_link = { type = "link", title = "CloudNativePG", url = "/d/${grafana_dashboard.cloudnative_pg.uid}", tags = [], asDropdown = false, keepTime = true, includeVars = false, targetBlank = false, icon = "dashboard", tooltip = "" }

  # Hidden constants the queries read: the node pool's bounds, and the spans whose duration says
  # nothing of slowness.
  journey_constants = {
    node_baseline   = local.node_pool.min_nodes
    node_maximum    = local.node_pool.max_nodes
    latency_ignores = join("|", distinct(concat([local.probes], flatten([for alert in values(var.alerts) : alert.latency_ignores]))))
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

# A panel without its own data source reads the stack's metrics.
resource "grafana_dashboard" "journey" {
  for_each = local.journey

  folder = grafana_folder.production.uid
  config_json = jsonencode(merge(jsondecode(file("${path.module}/dashboards/${each.key}.json")), {
    uid           = "journey-${each.key}"
    title         = each.value.title
    tags          = ["journey"]
    schemaVersion = 41
    time          = { from = each.value.from, to = "now" }
    refresh       = each.value.refresh
    links         = concat(local.journey_links, each.key == "health" ? [local.database_link] : [])
    templating = { list = [for name, value in local.journey_constants :
      { type = "constant", name = name, query = tostring(value), hide = 2 }
    ] }
    panels = [for panel in jsondecode(file("${path.module}/dashboards/${each.key}.json")).panels :
      merge({ datasource = { type = "prometheus", uid = local.metrics } }, panel)
    ]
  }))
}

resource "grafana_apps_dashboard_dashboard_v2" "services" {
  metadata {
    uid        = "journey-services"
    folder_uid = grafana_folder.production.uid
  }

  spec {
    title = "4. Services"
    tags  = ["journey"]
    json = jsonencode(merge(jsondecode(file("${path.module}/dashboards/services.json")), {
      title = "4. Services"
      tags  = ["journey"]
      links = local.journey_links
      timeSettings = {
        timezone             = "browser"
        from                 = "now-24h"
        to                   = "now"
        autoRefresh          = "5m"
        autoRefreshIntervals = ["1m", "5m", "15m", "1h"]
        hideTimepicker       = false
        fiscalYearStartMonth = 0
      }
    }))
  }
}

# The organization's home dashboard, the journey's first step, is set by hand: reading it needs a
# role that also writes the organization, which the plan token must not hold. Forgetting it keeps
# the setting.
removed {
  from = grafana_organization_preferences.home

  lifecycle {
    destroy = false
  }
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
