locals {
  repository_runtime = { for key, host in local.pgbackrest_repository : key => host.runtime if host.runtime != null }
  repository_cloud_config = { for key, runtime in local.repository_runtime : key => "#cloud-config\n${yamlencode({
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
          bucket    = "${trimsuffix(var.state_bucket, "-tofu-state")}-pgbr-json-keys"
          client_cn = "agora-database.${var.project_id}"
        })
      },
      {
        path        = "/etc/systemd/system/agora-backup-repository.service"
        permissions = "0644"
        content = templatefile("${path.module}/templates/repository.service.tftpl", merge(runtime, {
          project           = var.project_id
          management_number = trimprefix(trimsuffix(var.state_bucket, "-tofu-state"), "${var.management_project_id}-")
          server_name       = "agora-pgbackrest-json-keys.${var.database.zone}.c.${var.project_id}.internal"
        }))
      },
    ]
    # COS recreates /etc on every boot. Register the unit without starting or enabling it.
    runcmd = [["systemctl", "daemon-reload"]]
  })}" }
}

resource "google_artifact_registry_repository_iam_member" "repository_images" {
  for_each = length(local.repository_runtime) == 0 ? {} : google_artifact_registry_repository.images

  project    = var.project_id
  location   = each.value.location
  repository = each.value.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.repository["host"].email}"
}
