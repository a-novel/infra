# Plans the committed production inputs against mocked providers.
mock_provider "google" {}

mock_provider "grafana" {}

run "plans_with_the_read_only_token" {
  command = plan

  assert {
    condition     = local.token.secret == "production-grafana-plan-token" && local.cloud_token.secret == "production-grafana-cloud-plan-token"
    error_message = "Pull requests and the drift check run pull-request code, so they must read only the read-only tokens."
  }
}

run "deploys_with_the_write_token" {
  command = plan

  variables {
    writer = true
  }

  assert {
    condition     = local.token.secret == "production-grafana-deploy-token" && local.cloud_token.secret == "production-grafana-cloud-deploy-token"
    error_message = "Only a deploy may read the tokens that write."
  }
}

run "routes_every_alert_to_discord" {
  command = plan

  assert {
    condition = (
      grafana_notification_policy.discord.contact_point == var.contact_point &&
      length(grafana_notification_policy.discord.policy) == 0 &&
      alltrue(flatten([for group in grafana_rule_group.alerts : [for rule in group.rule : length(rule.notification_settings) == 0]]))
    )
    error_message = "Every alert must reach the Discord contact point: no nested policy or rule-level routing may divert one."
  }

  assert {
    condition = alltrue(flatten([for group in grafana_rule_group.alerts : [for rule in group.rule : (
      rule.no_data_state == "OK" && rule.condition == "firing" && contains(rule.data[*].ref_id, rule.condition)
    )]]))
    error_message = "Every rule must fire on any series its query returns, and stay quiet on none, as a Prometheus rule does."
  }

  assert {
    condition     = alltrue(flatten([for group in grafana_rule_group.alerts : [for rule in group.rule : rule.exec_err_state == "Error" && rule.for != "0s"]]))
    error_message = "A failed query must post DatasourceError only once it outlasts a pending period, or a single failed evaluation pages."
  }
}

run "watches_every_service" {
  command = plan

  assert {
    condition = alltrue([for service in keys(var.alerts) : toset(grafana_rule_group.alerts[service].rule[*].name) == toset([
      "${service}: failing share", "${service}: slow requests", "${service}: faults", "${service}: new fault",
    ])])
    error_message = "Every service needs its own rule group, with its failing share, latency, fault and new-fault alerts."
  }

  assert {
    condition = alltrue([for service in keys(var.alerts) : alltrue([
      for rule in grafana_rule_group.alerts[service].rule : strcontains(jsondecode(rule.data[0].model).expr, "service_name=\"${service}\"")
    ])])
    error_message = "A service's rules must read its own span metrics only."
  }
}

run "warns_before_resources_run_out" {
  command = plan

  assert {
    condition = (
      length(grafana_rule_group.alerts["capacity"].rule) == 6 + length(local.databases) &&
      alltrue([for name, database in local.databases : anytrue([for rule in grafana_rule_group.alerts["capacity"].rule :
        strcontains(jsondecode(rule.data[0].model).expr, "namespace=\"${name}\"") &&
        endswith(jsondecode(rule.data[0].model).expr, "> ${database.max_connections * var.thresholds.database_connections}")
      ])])
    )
    error_message = "The capacity group must warn on CPU, memory, out-of-memory kills, waiting pods and saturated autoscalers, and on each database's connections against its own limit."
  }

  assert {
    condition = alltrue([for rule in grafana_rule_group.alerts["capacity"].rule :
      !strcontains(jsondecode(rule.data[0].model).expr, "resource_requests") || strcontains(jsondecode(rule.data[0].model).expr, "resource_requests{resource=\"cpu\"}) > 0)")
    ])
    error_message = "A container without a CPU request must be left out, or its share divides by zero and fires."
  }
}

run "refuses_a_latency_alert_without_a_threshold" {
  command = plan

  variables {
    alerts = {
      "service-genai" = { failure_rate = 0.05, p95_seconds = 0 }
    }
  }

  expect_failures = [var.alerts]
}

run "leaves_mail_sends_out_of_latency" {
  command = plan

  # Prometheus anchors a label regex at both ends, as this one does.
  assert {
    condition     = can(regex("^(?:${join("|", var.alerts["service-authentication"].latency_ignores)})$", "core.MailDelivery(send)"))
    error_message = "Authentication's emails go out after their request answers, so its slow-requests alert must leave the send out. An ignore is a regular expression: write a parenthesis as [(]."
  }
}

run "leaves_streams_and_generations_out_of_latency" {
  command = plan

  assert {
    condition = alltrue([for span in ["GET /v1/project/stream", "GET /v1/generation/stream", "POST /v1/generation"] :
      can(regex("^(?:${join("|", var.alerts["service-narrative-engine"].latency_ignores)})$", span))
    ]) && !can(regex("^(?:${join("|", var.alerts["service-narrative-engine"].latency_ignores)})$", "GET /v1/generation"))
    error_message = "Narrative-engine's streams stay open and its generation submits wait on GenAI, so its slow-requests alert must leave them out, and them alone."
  }
}

# CloudNativePG's own collector reads 0 for the Barman Cloud plugin's backups, so a rule on it would
# fire on every database at once, or never.
run "watches_base_backups_through_the_plugin" {
  command = plan

  assert {
    condition = length([for rule in grafana_rule_group.alerts["platform"].rule : rule
      if rule.name == "Base backup stale" && strcontains(jsondecode(rule.data[0].model).expr, "barman_cloud_cloudnative_pg_io_last_available_backup_timestamp")
    ]) == 1 && !anytrue(flatten([for group in grafana_rule_group.alerts : [for rule in group.rule : strcontains(jsondecode(rule.data[0].model).expr, "cnpg_collector_last_available_backup_timestamp")]]))
    error_message = "A stale base backup must alert from the Barman Cloud plugin's timestamp, never from CloudNativePG's collector, which reads 0 for plugin backups."
  }
}

run "links_the_journey" {
  command = plan

  assert {
    condition = alltrue(concat(
      [for dashboard in grafana_dashboard.journey : contains(jsondecode(dashboard.config_json).tags, "journey") && jsondecode(dashboard.config_json).links[0].tags == ["journey"]],
      [contains(jsondecode(grafana_apps_dashboard_dashboard_v2.services.spec.json).tags, "journey") && jsondecode(grafana_apps_dashboard_dashboard_v2.services.spec.json).links[0].tags == ["journey"]],
    ))
    error_message = "Every journey dashboard must carry the journey tag and link the others through it."
  }

  # Grafana stores a transformation it does not recognize as an empty one, and the panel then shows
  # its queries unjoined.
  assert {
    condition = alltrue(flatten([for element in jsondecode(grafana_apps_dashboard_dashboard_v2.services.spec.json).elements : [
      for transformation in try(element.spec.data.spec.transformations, []) : transformation.kind == "Transformation" && transformation.group != "" && can(transformation.spec.options)
    ]]))
    error_message = "Each transformation of the Services dashboard must name its transformer in group, in the v2 schema."
  }
}

run "links_every_alert" {
  command = plan

  assert {
    condition = alltrue(flatten([for group in grafana_rule_group.alerts : [for rule in group.rule : (
      rule.annotations.runbook_url == local.runbook &&
      contains(concat([for key in keys(local.journey) : "journey-${key}"], ["journey-services", ""]), lookup(rule.annotations, "__dashboardUid__", ""))
    )]]))
    error_message = "Every alert must link the runbook, and a dashboard only of the journey."
  }

  assert {
    condition = alltrue(flatten([for group in grafana_rule_group.alerts : [for rule in group.rule :
      contains(rule.annotations.__dashboardUid__ == "journey-services"
        ? [for element in values(jsondecode(grafana_apps_dashboard_dashboard_v2.services.spec.json).elements) : tostring(element.spec.id)]
        : [for panel in jsondecode(grafana_dashboard.journey[trimprefix(rule.annotations.__dashboardUid__, "journey-")].config_json).panels : tostring(panel.id)],
      rule.annotations.__panelId__)
      if can(rule.annotations.__dashboardUid__)
    ]]))
    error_message = "An alert must link a panel its dashboard holds."
  }

  assert {
    condition     = strcontains(grafana_message_template.discord.template, "define \"discord.title\"") && strcontains(grafana_message_template.discord.template, "define \"discord.message\"")
    error_message = "The contact point calls discord.title and discord.message, so the template must define both."
  }
}

run "watches_every_counter_store" {
  command = plan

  assert {
    condition = length(local.counter_stores) > 0 && toset(grafana_rule_group.alerts["rate-limits"].rule[*].name) == toset(flatten([for service in local.counter_stores : [
      "${service}: counter store down", "${service}: rate limits counted locally", "${service}: counters evicted",
    ]]))
    error_message = "Each counter store needs three alerts: the store down, counting in the pods while it answers, and an evicted counter."
  }

  # Each rule reads its own store, names its service, and links that store's panel.
  assert {
    condition = alltrue([for rule in grafana_rule_group.alerts["rate-limits"].rule : alltrue([
      strcontains(jsondecode(rule.data[0].model).expr, "{namespace=\"${split(":", rule.name)[0]}\"}"),
      strcontains(rule.annotations.summary, "The ${split(":", rule.name)[0]} "),
      startswith(one([for name, element in jsondecode(grafana_apps_dashboard_dashboard_v2.services.spec.json).elements : name if tostring(element.spec.id) == rule.annotations.__panelId__]), "${split(":", rule.name)[0]}-"),
    ])])
    error_message = "A store's alerts must read its own namespace, name its service in their summary, and link that service's panels."
  }

  # The exporter runs beside Valkey, so a store whose pod is gone sends no series.
  assert {
    condition = alltrue([for service in local.counter_stores :
      strcontains(jsondecode(one([for rule in grafana_rule_group.alerts["rate-limits"].rule : rule if rule.name == "${service}: counter store down"]).data[0].model).expr, "or absent(redis_up{")
    ])
    error_message = "The store-down alert must also fire when the store sends no series."
  }

  assert {
    condition = alltrue([for service in local.counter_stores : alltrue([for fragment in ["service_name=\"service-${service}\", rate_limit_local=\"true\"", "and on () max(redis_up{"] :
      strcontains(jsondecode(one([for rule in grafana_rule_group.alerts["rate-limits"].rule : rule if rule.name == "${service}: rate limits counted locally"]).data[0].model).expr, fragment)
    ])])
    error_message = "The counting-locally alert must read its own service's spans' rate_limit.local, and fire only while the store answers, since the store-down alert reports the rest."
  }
}

run "alerts_before_grafana_bills_overage" {
  command = plan

  assert {
    condition = (
      length(grafana_rule_group.alerts["usage"].rule) == length(local.allowances) + 1 &&
      alltrue([for rule in grafana_rule_group.alerts["usage"].rule : rule.data[0].datasource_uid == "grafanacloud-usage"]) &&
      contains(grafana_rule_group.alerts["usage"].rule[*].name, "Usage: overage")
    )
    error_message = "Every Grafana Cloud allowance needs its usage alert, and any overage its own, read from the usage data source."
  }

  assert {
    condition = alltrue(flatten([for name, group in grafana_rule_group.alerts : [
      for rule in group.rule : rule.data[0].datasource_uid == (rule.name == "Gateway refused" ? "grafanacloud-logs" : "grafanacloud-prom")
    ] if name != "usage"]))
    error_message = "Every other alert reads the metrics Alloy sends, except the Gateway alert, which reads the cluster's events."
  }

  assert {
    condition     = jsondecode(one([for rule in grafana_rule_group.alerts["platform"].rule : rule if rule.name == "Gateway refused"]).data[0].model).queryType == "instant"
    error_message = "The Gateway alert must ask Loki for an instant value: a rule cannot fire on the range Loki answers otherwise."
  }

  assert {
    condition = alltrue(flatten([for group in grafana_rule_group.alerts : [
      for rule in group.rule : [for query in rule.data : query.query_type == lookup(jsondecode(query.model), "queryType", null)]
    ]]))
    error_message = "Grafana copies a query model's queryType onto the query, so query_type must repeat it, or every plan rewrites the rule group."
  }
}

run "pins_the_cloudnative_pg_dashboard" {
  command = plan

  assert {
    condition     = filesha256("dashboards/cloudnative-pg.json") == local.cloudnative_pg.sha256
    error_message = "The vendored CloudNativePG dashboard must be its pinned release, byte for byte. An update replaces the file, its release and its digest together."
  }

  assert {
    condition = alltrue([for variable in jsondecode(grafana_dashboard.cloudnative_pg.config_json).templating.list :
      variable.current.value == "grafanacloud-prom" if variable.type == "datasource"
    ])
    error_message = "The CloudNativePG dashboard must read the stack's metrics."
  }
}

run "keeps_each_faro_app_to_its_platform" {
  command = plan

  assert {
    condition = alltrue([for platform, app in grafana_frontend_o11y_app.platform :
      jsonencode(app.allowed_origins) == jsonencode([var.faro_apps[platform]]) && jsonencode(app.settings) == jsonencode({ "geolocation.enabled" = "0" })
    ]) && length(grafana_frontend_o11y_app.platform) == length(var.faro_apps)
    error_message = "Each platform's Faro app must take signals from its own origin alone and derive no place from a visitor's address."
  }
}

run "refuses_a_faro_origin_with_a_path" {
  command = plan

  variables {
    faro_apps = { "platform-account" = "https://account.storyverse.fr/" }
  }

  expect_failures = [var.faro_apps]
}
