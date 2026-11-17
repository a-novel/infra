# The jobs that run outside a deploy: those their schedules start, and the maintenance operations the
# named operators start. A failed run is not retried: the next one takes over, or the operator runs
# it again.
locals {
  scheduled_jobs = {
    # JSON Keys signs nothing until a first run creates each usage's key. Later runs rotate a key once
    # its interval has elapsed.
    rotate-keys = {
      service    = "json-keys"
      image      = "json-keys/rotatekeys"
      schedule   = "10 * * * *"
      suspend    = false
      args       = []
      env        = {}
      secret_env = { APP_MASTER_KEY = { secret = "secrets", key = "APP_MASTER_KEY" } }
    }
    # Deletes the sign-out revocations of expired refresh tokens.
    refresh-token-purge = {
      service    = "authentication"
      image      = "authentication/maintenance"
      schedule   = "40 3 * * *"
      suspend    = false
      args       = ["refresh-token-purge"]
      env        = {}
      secret_env = {}
    }
    # Deletes the expired authorization codes, after the refresh token purge.
    authorization-code-purge = {
      service    = "authentication"
      image      = "authentication/maintenance"
      schedule   = "50 3 * * *"
      suspend    = false
      args       = ["authorization-code-purge"]
      env        = {}
      secret_env = {}
    }
    # The maintenance template never runs on its own. The named operators' Jobs copy it and name
    # their operation in its arguments (maintenance.tf). Without one, the image prints its help.
    # account-role sends its mail within SMTP_TIMEOUT, and the deadline leaves room for the exit.
    maintenance = {
      service    = "authentication"
      image      = "authentication/maintenance"
      schedule   = "0 0 1 1 *"
      suspend    = true
      args       = []
      env        = local.authentication_mail_env
      secret_env = {}
    }
  }
}

module "scheduled" {
  source   = "../../../modules/cluster-job"
  for_each = var.custom_resources ? local.scheduled_jobs : {}

  name      = each.key
  namespace = kubernetes_namespace_v1.service[each.value.service].metadata[0].name
  schedule  = each.value.schedule
  suspend   = each.value.suspend
  # As the migrations' pods: the job reaches its database by the certificate's name.
  labels = merge(local.database_clients, { "app.kubernetes.io/name" = each.key })

  container_name = each.key
  image          = local.release_image[each.value.image]
  args           = each.value.args
  # Each job runs one statement at a time, so one connection serves it.
  env = merge(local.database_env[each.value.service], local.downtime_env[each.value.service], each.value.env, local.telemetry_env[each.value.service].job, {
    SSL_CERT_DIR            = "/etc/ssl/certs:/etc/database-ca"
    POSTGRES_MAX_OPEN_CONNS = "1"
  })
  secret_env = [for name, ref in merge(local.database_secret_env, each.value.secret_env) : merge(ref, { name = name })]
  ca_secret  = kubernetes_manifest.database_server_certificate[each.value.service].manifest.spec.secretName
  resources  = { cpu = "100m", memory = "256Mi" }

  active_deadline_seconds = 600

  depends_on = [module.migrations, kubernetes_manifest.secrets]
}

moved {
  from = kubernetes_cron_job_v1.scheduled["rotate-keys"]
  to   = module.scheduled["rotate-keys"].kubernetes_cron_job_v1.cron_job
}

moved {
  from = kubernetes_cron_job_v1.scheduled["refresh-token-purge"]
  to   = module.scheduled["refresh-token-purge"].kubernetes_cron_job_v1.cron_job
}

moved {
  from = kubernetes_cron_job_v1.scheduled["authorization-code-purge"]
  to   = module.scheduled["authorization-code-purge"].kubernetes_cron_job_v1.cron_job
}

moved {
  from = kubernetes_cron_job_v1.scheduled["maintenance"]
  to   = module.scheduled["maintenance"].kubernetes_cron_job_v1.cron_job
}
