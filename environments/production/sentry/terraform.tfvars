management_project_id = "a-novel-management-prod"

# The US organization, until a-novel/infra#1107 moves to the EU one.
organization = "a-novel"
base_url     = "https://sentry.io/api/"
team         = "a-novel-devs"

projects = [
  "service-authentication",
  "service-genai",
  "service-json-keys",
]

token_versions = {
  plan   = 1
  deploy = 1
}

discord = {
  server     = "Agora Storyverse"
  channel_id = "1564067364591509525" # sentry-alerts
}

# Tune these on real traffic. A no-data window outlasts the gap between the service's steady span
# sources, so a night without users stays quiet.
alerts = {
  # The health check runs every three hours; the liveness probe sends no span.
  "service-authentication" = { failure_rate = 0.05, p95_ms = 1000, no_data_seconds = 14400 }
  # The sweep runs every minute; generation calls the model and runs long.
  "service-genai" = { failure_rate = 0.05, p95_ms = 60000, no_data_seconds = 600 }
  # Authentication's health check calls it every three hours, until the rotation job traces too.
  "service-json-keys" = { failure_rate = 0.05, p95_ms = 500, no_data_seconds = 14400 }
}
