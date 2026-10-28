# Plans the committed production inputs against mocked providers.
mock_provider "google" {}

mock_provider "sentry" {}

run "plans_with_the_read_only_token" {
  command = plan

  assert {
    condition     = local.token.secret == "production-sentry-plan-token"
    error_message = "Pull requests and the drift check run pull-request code, so they must read only the read-only token."
  }

  assert {
    condition     = alltrue([for repository, project in sentry_project.service : project.slug == repository])
    error_message = "Release CI names each Sentry project after its repository, so the slugs must match."
  }

  assert {
    condition     = alltrue([for protection in sentry_project_spike_protection.service : protection.enabled])
    error_message = "Every project needs spike protection, so one runaway fault cannot spend the shared error quota."
  }
}

run "deploys_with_the_write_token" {
  command = plan

  variables {
    writer = true
  }

  assert {
    condition     = local.token.secret == "production-sentry-deploy-token"
    error_message = "Only a deploy may read the token that writes."
  }
}

run "watches_every_service" {
  command = plan

  assert {
    condition = alltrue([for repository in var.projects : alltrue([
      for kind in ["failures", "latency", "silence"] : contains(keys(sentry_metric_monitor.service), "${repository}/${kind}")
    ])])
    error_message = "Every service needs its failure, latency and no-data monitors, or a broken service stays silent."
  }

  assert {
    condition     = alltrue([for repository in var.projects : !sentry_project_inbound_data_filter.health_checks[repository].active])
    error_message = "Sentry's health-check filter drops the health check's span, the steady source the no-data monitors count."
  }

  assert {
    condition     = sentry_alert.discord.action_filters[0].actions[0].discord.channel_id == var.discord.channel_id
    error_message = "The alerts must post to the Discord channel the team watches."
  }
}
