output "services" {
  description = "Each service's Sentry project ID, public DSN and OTLP header, by repository."
  value = {
    for repository, key in data.sentry_key.service : repository => {
      project_id   = key.project_id
      dsn          = nonsensitive(key.dsn["public"])
      otlp_headers = "x-sentry-auth=sentry sentry_key=${key.public}"
    }
  }
}
