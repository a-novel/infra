locals {
  server_name = "agora-pgbackrest-${var.service}.${var.placement.zone}.c.${var.project_id}.internal"

  # COS rebuilds /etc on boot; cloud-init writes the units and starts the
  # repository on every boot. Changing this metadata applies on the next restart.
  cloud_config = "#cloud-config\n${yamlencode({
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
        content = templatefile("${path.module}/templates/pgbackrest.conf.tftpl", {
          bucket    = var.bucket
          service   = var.service
          client_cn = var.runtime.client_name
        })
      },
      {
        path        = "/etc/systemd/system/agora-backup-repository.service"
        permissions = "0644"
        content = templatefile("${path.module}/templates/repository.service.tftpl", merge(var.runtime, {
          project           = var.project_id
          service           = var.service
          management_number = var.management_project_number
          server_name       = local.server_name
          restart           = "on-failure"
        }))
      },
    ]
    runcmd = [
      ["systemctl", "daemon-reload"],
      ["ssh-keygen", "-lf", "/mnt/stateful_partition/etc/ssh/ssh_host_ed25519_key.pub", "-E", "sha256"],
      ["systemctl", "start", "agora-backup-repository.service"],
    ]
  })}"
}

resource "google_service_account" "repository" {
  project      = var.project_id
  account_id   = "agora-pgbr-${var.service}"
  display_name = "A-Novel ${var.service} native backup repository"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account_iam_member" "deployer" {
  service_account_id = google_service_account.repository.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.deployer}"
}

# The repository host pulls its images from the service's private repositories. The database
# host's own grant lives in service-runtime, so a host without backups pulls too.
resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each = { for purpose, repository in var.repository_ids : "${purpose}/repository" => repository }

  project    = var.project_id
  location   = var.region
  repository = each.value
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.repository.member
}

resource "google_compute_instance" "repository" {
  project                   = var.project_id
  zone                      = var.placement.zone
  name                      = "agora-pgbackrest-${var.service}"
  machine_type              = var.machine_type
  desired_status            = "RUNNING"
  allow_stopping_for_update = false
  deletion_protection       = false
  can_ip_forward            = false
  tags                      = ["agora-pgbackrest-${var.service}"]
  # config fingerprints the cloud-config the VM boots from. The rollout restarts the VM while
  # running-config differs from it, then sets running-config. OpenTofu manages only the labels
  # listed here, so it leaves running-config alone.
  labels = {
    component = var.service
    role      = "backup-repository"
    config    = substr(sha256(local.cloud_config), 0, 16)
  }

  boot_disk {
    auto_delete = true
    initialize_params {
      image = var.placement.cos_image
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = var.placement.subnetwork
    network_ip = var.placement.ip
  }

  service_account {
    email  = google_service_account.repository.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    block-project-ssh-keys    = "TRUE"
    cos-update-strategy       = "update_disabled"
    disable-legacy-endpoints  = "TRUE"
    enable-guest-attributes   = "FALSE"
    enable-oslogin            = "TRUE"
    google-logging-enabled    = "false"
    google-monitoring-enabled = "false"
    serial-port-enable        = "FALSE"
    user-data                 = local.cloud_config
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
    provisioning_model  = "STANDARD"
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = true
    enable_vtpm                 = true
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_service_account_iam_member.deployer]
}
