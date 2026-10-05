resource "google_compute_disk" "data" {
  for_each = local.hosts

  project = each.value.project
  zone    = each.value.zone
  name    = "agora-native-recovery-data"
  type    = "pd-ssd"
  size    = each.value.disk_gib
  labels  = { purpose = "native-recovery", service = "json-keys" }
}

resource "google_compute_instance" "recovery" {
  for_each = local.hosts

  project        = each.value.project
  zone           = each.value.zone
  name           = "agora-native-recovery"
  machine_type   = "e2-medium"
  desired_status = "TERMINATED"
  can_ip_forward = false
  labels         = { purpose = "native-recovery", service = "json-keys" }
  metadata = {
    block-project-ssh-keys   = "TRUE"
    disable-legacy-endpoints = "TRUE"
    enable-oslogin           = "TRUE"
    serial-port-enable       = "FALSE"
    user-data = "#cloud-config\n${yamlencode({
      # COS serves persistent keys, not the /etc/ssh keys cloud-init reports.
      ssh_deletekeys = false
      write_files = concat([
        {
          path        = "/etc/agora-recovery/request.json"
          permissions = "0444"
          content     = jsonencode(local.requests[each.key])
        },
        {
          path        = "/etc/agora-recovery/docker/config.json"
          permissions = "0600"
          content     = jsonencode({ credHelpers = { "europe-west1-docker.pkg.dev" = "gcr" } })
        },
        ], [for name, network in { restore = "bridge", verify = "none" } : {
          path                             = "/etc/systemd/system/agora-native-${name}.service"
          permissions                      = "0644"
          content                          = templatefile("${path.module}/restore.service.tftpl", { image = each.value.restore_image, name = name, network = network })
      }])
      # Creation boots briefly even with a stopped desired state; preparation must not start work.
      runcmd = [["systemctl", "daemon-reload"]]
    })}"
  }

  boot_disk {
    auto_delete = true
    initialize_params {
      image = each.value.cos_image
      size  = 20
      type  = "pd-standard"
    }
  }
  attached_disk {
    source      = google_compute_disk.data[each.key].self_link
    device_name = "agora-native-recovery-data"
    mode        = "READ_WRITE"
  }
  network_interface {
    subnetwork = google_compute_subnetwork.recovery[each.key].self_link
  }
  service_account {
    email  = "pgbr-json-keys-recovery@${each.value.management_project}.iam.gserviceaccount.com"
    scopes = ["cloud-platform"]
  }
  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = true
    enable_vtpm                 = true
  }
  scheduling {
    automatic_restart           = false
    on_host_maintenance         = "MIGRATE"
    provisioning_model          = "STANDARD"
    instance_termination_action = "STOP"
    max_run_duration {
      seconds = 14400
    }
  }
}

output "recovery" {
  description = "Prepared host coordinates. These do not authorize execution or establish successful database recovery."
  value = { for key, host in local.hosts : key => {
    project          = host.project
    zone             = host.zone
    host             = google_compute_instance.recovery[key].name
    disk             = google_compute_disk.data[key].name
    request          = local.requests[key]
    instance_id      = google_compute_instance.recovery[key].instance_id
    disk_id          = google_compute_disk.data[key].disk_id
    user_data_sha256 = sha256(google_compute_instance.recovery[key].metadata["user-data"])
  } }
}
