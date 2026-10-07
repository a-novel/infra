locals {
  repository_runtime = { for key, host in local.pgbackrest_repository : key => host.runtime if host.runtime != null }
  repository_cloud_config = { for key, runtime in local.repository_runtime : key => "#cloud-config\n${yamlencode({
    # COS serves persistent keys, not the /etc/ssh keys cloud-init reports.
    ssh_deletekeys = false
    write_files = [
      {
        path        = "/etc/agora-backup/docker/config.json"
        permissions = "0600"
        content     = jsonencode({ credHelpers = { "${var.region}-docker.pkg.dev" = "gcr" } })
      },
      {
        path        = "/etc/agora-backup/pgbackrest.conf"
        permissions = "0444"
        content = templatefile("${path.module}/templates/repository.conf.tftpl", {
          bucket    = "${trimsuffix(var.state_bucket, "-tofu-state")}-pgbr-${var.service}"
          service   = var.service
          client_cn = runtime.client_name
        })
      },
      {
        path        = "/etc/systemd/system/agora-backup-repository.service"
        permissions = "0644"
        content = templatefile("${path.module}/templates/repository.service.tftpl", merge(runtime, {
          project           = var.project_id
          service           = var.service
          management_number = trimprefix(trimsuffix(var.state_bucket, "-tofu-state"), "${var.management_project_id}-")
          server_name       = local.repository_name
          zone_argument     = var.zone == null ? "" : "--zone=private "
          restart           = var.pgbackrest_repository.active ? "on-failure" : "no"
        }))
      },
    ]
    # COS recreates /etc on every boot; activation must survive a host restart.
    runcmd = concat([["systemctl", "daemon-reload"]], var.pgbackrest_repository.active ? [
      ["ssh-keygen", "-lf", "/mnt/stateful_partition/etc/ssh/ssh_host_ed25519_key.pub", "-E", "sha256"],
      ["systemctl", "start", "agora-backup-repository.service"],
    ] : [])
  })}" }
}

resource "google_artifact_registry_repository_iam_member" "shared_database_images" {
  for_each = var.zone == "private" && length(local.repository_runtime) > 0 ? google_artifact_registry_repository.images : {}

  project    = var.project_id
  location   = each.value.location
  repository = each.value.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.service == "authentication" ? "agora-auth-database" : "agora-json-keys-database"}@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_artifact_registry_repository_iam_member" "repository_images" {
  for_each = length(local.repository_runtime) == 0 ? {} : google_artifact_registry_repository.images

  project    = var.project_id
  location   = each.value.location
  repository = each.value.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.repository["host"].email}"
}
