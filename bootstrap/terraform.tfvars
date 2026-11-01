management_project_id    = "a-novel-management-prod"
region                   = "europe-west9"
storage_location         = "EU"
downtime_webhook_version = 1
github_dispatch_token_versions = {
  a-novel     = 1
  a-novel-kit = 1
}
operator_principals = [
  "user:geoffroy.vincent@agorastoryverse.com",
]
cluster_databases = {
  workload_project_id = "a-novel-production-prod"
  services = [
    "authentication",
    "genai",
    "json-keys",
    "narrative-engine",
  ]
}
# The lineages the cluster's databases archived to before their current one.
retired_barman_lineages = ["database-paris-2", "database-rehearsal", "database-rehearsal-2", "database-rehearsal-3"]
