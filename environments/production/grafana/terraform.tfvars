management_project_id = "a-novel-management-prod"

# The production stack, in prod-eu-west-2.
url      = "https://anovel.grafana.net"
stack_id = 1896612

token_versions = {
  plan   = 2
  deploy = 1
}

contact_point = "discord"

# Tune these on real traffic. The thresholds read the span metrics' 10-minute rates.
alerts = {
  # Their server-side rendering waits on Authentication.
  "platform-account" = { failure_rate = 0.05, p95_seconds = 2 }
  "platform-studio"  = { failure_rate = 0.05, p95_seconds = 2 }
  # Its health check, every five minutes, also reaches the database and the mail relay, and took
  # 0.9 seconds at the 95th percentile on 2026-10-30.
  "service-authentication" = { failure_rate = 0.05, p95_seconds = 2 }
  # A generation stream stays open until the model has finished writing.
  "service-genai"     = { failure_rate = 0.05, p95_seconds = 1, latency_ignores = ["anovel.genai.v0.GenerationStreamService/GenerationStream"] }
  "service-json-keys" = { failure_rate = 0.05, p95_seconds = 0.5 }
}

# The volume thresholds match the database hosts' disk alerts in foundation.
thresholds = {
  volume_warning  = 0.7
  volume_critical = 0.85
  node_cpu        = 0.8
  node_memory     = 0.85
  replica_lag     = 30
  usage           = 0.8
  # Early enough to raise a request, a limit or max_connections before the resource runs out.
  container_cpu        = 0.8
  container_memory     = 0.85
  database_connections = 0.8
  service_budget       = 0.8
}
