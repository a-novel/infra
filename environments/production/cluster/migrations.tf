# Each new migrations image runs once, before its service's server rolls. A finished Job stays as its
# record. It runs only once the operators' kinds exist, since it reads the database's Secret. A new
# database lineage names a new Job too: the new database starts empty, and only the migrations
# schedule pg_cron's jobs (a-novel/service-genai#486). A Job's template can't change once created.
module "migrations" {
  source   = "../../../modules/cluster-job"
  for_each = var.custom_resources ? toset([for service, pins in local.release_pins : service if contains(keys(pins), "migrations")]) : toset([])

  name      = "migrations-${substr(trimprefix(local.release_images["${each.key}/migrations"].digest, "sha256:"), 0, 12)}-${substr(sha256(var.backup_server_name), 0, 8)}"
  namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
  labels    = merge(local.database_clients, { "app.kubernetes.io/name" = "migrations" })

  container_name = "migrations"
  image          = local.release_image["${each.key}/migrations"]
  # golib holds one connection for its migration lock and applies the migrations on another.
  env = merge(local.database_env[each.key], local.downtime_env[each.key], {
    SSL_CERT_DIR            = "/etc/ssl/certs:/etc/database-ca"
    POSTGRES_MAX_OPEN_CONNS = "2"
  })
  secret_env = [for name, ref in local.database_secret_env : merge(ref, { name = name })]
  # The migrations trust the database's CA as the server does.
  ca_secret = kubernetes_manifest.database_server_certificate[each.key].manifest.spec.secretName
  resources = { cpu = "100m", memory = "256Mi" }

  # Kubernetes ends a migration after 40 minutes, before the deploy stops waiting on it. A run that
  # outlived the wait would stay tainted and running, and the next deploy's replacement would kill
  # it. The wait fits the one-hour token the deploy reaches the cluster with.
  active_deadline_seconds = 2400
  timeout                 = "45m"

  depends_on = [kubernetes_manifest.database, kubernetes_network_policy_v1.database_clients]
}
