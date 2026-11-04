# Each platform's Frontend Observability app, which Faro reports the browser's telemetry to
# (a-novel/.github#527). The collector takes signals from the platform's own origin alone, and derives
# no place from a visitor's address.
resource "grafana_frontend_o11y_app" "platform" {
  for_each = var.faro_apps

  stack_id             = var.stack_id
  name                 = each.key
  allowed_origins      = [each.value]
  extra_log_attributes = {}
  settings             = { "geolocation.enabled" = "0" }
}

output "faro_collectors" {
  description = "Each platform's Faro collector URL, by repository, which the cluster root gives it as PUBLIC_FARO_URL. A browser reads it, so it is public."
  value       = { for platform, app in grafana_frontend_o11y_app.platform : platform => app.collector_endpoint }
}

output "faro_app_ids" {
  description = "Each platform's Faro app ID, by repository, which the GitHub root gives the platform's release build as FARO_SOURCEMAP_APP_ID to upload its source maps."
  value       = { for platform, app in grafana_frontend_o11y_app.platform : platform => app.id }
}
