# Compose the tested storage contract without moving the original trial's state addresses.
module "repository" {
  source            = "../gcs-storage"
  project_id        = var.project_id
  service           = var.service
  retention_seconds = var.retention_seconds
}

resource "google_compute_disk" "data" {
  project = var.project_id
  zone    = "europe-west1-d"
  name    = "pgbackrest-proof-data"
  type    = "pd-ssd"
  size    = 10
  labels  = { purpose = "pgbackrest-gcs-proof", service = var.service }
}

resource "google_compute_instance" "trial" {
  project        = var.project_id
  zone           = "europe-west1-d"
  name           = "pgbackrest-proof"
  machine_type   = "e2-medium"
  can_ip_forward = false
  labels         = { purpose = "pgbackrest-gcs-proof", service = var.service }
  metadata = {
    block-project-ssh-keys   = "TRUE"
    disable-legacy-endpoints = "TRUE"
    enable-oslogin           = "TRUE"
    serial-port-enable       = "FALSE"
  }

  boot_disk {
    auto_delete = true
    initialize_params {
      image = var.cos_image
      size  = 20
      type  = "pd-ssd"
    }
  }
  attached_disk {
    source      = google_compute_disk.data.self_link
    device_name = "pgbackrest-proof-data"
    mode        = "READ_WRITE"
  }
  network_interface {
    subnetwork = google_compute_subnetwork.trial.self_link
    # No access_config: IAP is the only SSH entry; PostgreSQL gets no ingress rule.
  }
  service_account {
    email  = module.repository.trial.writer
    scopes = ["cloud-platform"]
  }
  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = true
    enable_vtpm                 = true
  }
  scheduling {
    automatic_restart           = false
    on_host_maintenance         = "TERMINATE"
    provisioning_model          = "STANDARD"
    instance_termination_action = "STOP"
    max_run_duration {
      seconds = 14400
    }
  }
}
