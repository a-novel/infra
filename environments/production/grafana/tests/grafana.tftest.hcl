# Plans the committed production inputs against mocked providers.
mock_provider "google" {}

mock_provider "grafana" {}

run "plans_with_the_read_only_token" {
  command = plan

  assert {
    condition     = local.token.secret == "production-grafana-plan-token"
    error_message = "Pull requests and the drift check run pull-request code, so they must read only the read-only token."
  }
}

run "deploys_with_the_write_token" {
  command = plan

  variables {
    writer = true
  }

  assert {
    condition     = local.token.secret == "production-grafana-deploy-token"
    error_message = "Only a deploy may read the token that writes."
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

run "opens_on_the_journey" {
  command = plan

  assert {
    condition     = grafana_organization_preferences.home.home_dashboard_uid == grafana_dashboard.journey["errors"].uid
    error_message = "Grafana must open on the journey's first step."
  }

  assert {
    condition = alltrue(concat(
      [for dashboard in grafana_dashboard.journey : contains(jsondecode(dashboard.config_json).tags, "journey") && jsondecode(dashboard.config_json).links[0].tags == ["journey"]],
      [contains(jsondecode(grafana_apps_dashboard_dashboard_v2.services.spec.json).tags, "journey") && jsondecode(grafana_apps_dashboard_dashboard_v2.services.spec.json).links[0].tags == ["journey"]],
    ))
    error_message = "Every journey dashboard must carry the journey tag and link the others through it."
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
    condition     = strcontains(grafana_message_template.discord.template, "define \"discord.title\"") && strcontains(grafana_message_template.discord.template, "define \"discord.message\"")
    error_message = "The contact point calls discord.title and discord.message, so the template must define both."
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
    condition     = alltrue(flatten([for name, group in grafana_rule_group.alerts : [for rule in group.rule : rule.data[0].datasource_uid == "grafanacloud-prom"] if name != "usage"]))
    error_message = "Every other alert reads the metrics Alloy sends."
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
