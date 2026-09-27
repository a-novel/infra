mock_provider "google" {}

variables {
  project_id        = "a-novel-gcs-proof-pgbr260927"
  service           = "json-keys"
  retention_seconds = 600
  cos_image         = "projects/cos-cloud/global/images/cos-125-19216-104-97"
}

run "private_bounded_host" {
  command = plan

  assert {
    condition = {
      external_ips = length(google_compute_instance.trial.network_interface[0].access_config)
      forward      = google_compute_instance.trial.can_ip_forward
      secure_boot  = google_compute_instance.trial.shielded_instance_config[0].enable_secure_boot
      boot_ssd     = google_compute_instance.trial.boot_disk[0].initialize_params[0].type
      data_ssd     = google_compute_disk.data.type
      auto_restart = google_compute_instance.trial.scheduling[0].automatic_restart
      maintenance  = google_compute_instance.trial.scheduling[0].on_host_maintenance
      limit        = google_compute_instance.trial.scheduling[0].max_run_duration[0].seconds
      on_limit     = google_compute_instance.trial.scheduling[0].instance_termination_action
      metadata     = google_compute_instance.trial.metadata
      } == {
      external_ips = 0, forward = false, secure_boot = true,
      boot_ssd     = "pd-ssd", data_ssd = "pd-ssd", auto_restart = false, limit = 14400, on_limit = "STOP",
      maintenance  = "MIGRATE",
      metadata = tomap({
        block-project-ssh-keys = "TRUE", disable-legacy-endpoints = "TRUE",
        enable-oslogin         = "TRUE", serial-port-enable = "FALSE"
      })
    }
    error_message = "Keep the empty host private and shielded, with SSDs, OS Login and a native bounded stop; never start a database from metadata."
  }

  assert {
    condition = (
      google_compute_instance.trial.service_account[0].email == module.repository.trial.writer &&
      google_compute_instance.trial.attached_disk[0].source == google_compute_disk.data.self_link &&
      google_compute_instance.trial.network_interface[0].subnetwork == google_compute_subnetwork.trial.self_link
    )
    error_message = "The host must use only this trial's writer, separately retained disk and private subnet."
  }

  assert {
    condition = (
      google_compute_firewall.iap.source_ranges == toset(["35.235.240.0/20"]) &&
      google_compute_firewall.iap.direction == "INGRESS" &&
      one(google_compute_firewall.iap.allow).protocol == "tcp" &&
      one(google_compute_firewall.iap.allow).ports == tolist(["22"]) &&
      google_compute_firewall.https.direction == "EGRESS" &&
      one(google_compute_firewall.https.allow).protocol == "tcp" &&
      one(google_compute_firewall.https.allow).ports == tolist(["443"]) &&
      google_compute_firewall.deny_egress.direction == "EGRESS" &&
      google_compute_firewall.deny_egress.destination_ranges == toset(["0.0.0.0/0"]) &&
      google_compute_firewall.https.priority < google_compute_firewall.deny_egress.priority &&
      one(google_compute_firewall.deny_egress.deny).protocol == "all" &&
      google_compute_subnetwork.trial.private_ip_google_access &&
      !google_compute_network.trial.auto_create_subnetworks
    )
    error_message = "Expose SSH only through IAP, allow HTTPS out and deny other egress in a dedicated network."
  }
}

run "reject_previous_storage_trial" {
  command = plan
  variables { project_id = "a-novel-gcs-proof-20260927" }
  expect_failures = [var.project_id]
}

run "reject_floating_os" {
  command = plan
  variables { cos_image = "projects/cos-cloud/global/images/family/cos-stable" }
  expect_failures = [var.cos_image]
}
