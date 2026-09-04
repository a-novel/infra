locals {
  database_device_name = "agora-data"

  database_machine_profiles = {
    e2-medium = {
      memory_mb = 4096
      vcpu      = 2
    }
    e2-standard-2 = {
      memory_mb = 8192
      vcpu      = 2
    }
    e2-standard-4 = {
      memory_mb = 16384
      vcpu      = 4
    }
  }

  database_ports = {
    json_keys      = 5432
    authentication = 5433
  }
}

check "database_zone_matches_region" {
  assert {
    condition     = startswith(var.database_zone, "${var.region}-")
    error_message = "The database zone must belong to the configured production region."
  }
}

check "database_container_memory_headroom" {
  assert {
    condition = (
      (var.database_container_memory_mb * length(local.database_ports)) <=
      (local.database_machine_profiles[var.database_machine_type].memory_mb - 1024)
    )
    error_message = "Database container limits must leave at least 1 GiB of host memory."
  }
}

check "database_container_cpu_headroom" {
  assert {
    condition = (
      (var.database_container_cpu * length(local.database_ports)) <=
      (local.database_machine_profiles[var.database_machine_type].vcpu - 0.5)
    )
    error_message = "Database container limits must leave at least 0.5 vCPU for the host."
  }
}

resource "google_compute_disk" "database" {
  project = google_project.workload.project_id
  zone    = var.database_zone
  name    = local.database_device_name

  type                      = "pd-balanced"
  size                      = var.database_data_disk_size_gb
  physical_block_size_bytes = 4096
  description               = "Preserved data for the production PostgreSQL containers."

  labels = merge(local.labels, { role = "database-data" })

  deletion_policy = "DELETE"

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
}

resource "google_compute_instance_template" "database" {
  project     = google_project.workload.project_id
  region      = var.region
  name_prefix = "agora-database-"

  description          = "Immutable Container-Optimized OS template for the production PostgreSQL host."
  instance_description = "One-member private PostgreSQL data plane."
  machine_type         = var.database_machine_type
  can_ip_forward       = false

  tags   = [local.network_tags.database]
  labels = merge(local.labels, { role = "database" })

  metadata = {
    agora-database-container-cpu       = tostring(var.database_container_cpu)
    agora-database-container-memory-mb = tostring(var.database_container_memory_mb)
    agora-database-data-disk-size-gb   = tostring(var.database_data_disk_size_gb)
    agora-database-max-connections     = tostring(var.database_max_connections)
    agora-management-project-id        = var.management_project_id
    agora-registry-host                = "${var.region}-docker.pkg.dev"
    block-project-ssh-keys             = "TRUE"
    cos-update-strategy                = "update_disabled"
    disable-legacy-endpoints           = "TRUE"
    enable-guest-attributes            = "TRUE"
    enable-oslogin                     = "TRUE"
    google-logging-enabled             = "true"
    google-monitoring-enabled          = "true"
    serial-port-enable                 = "FALSE"
    shutdown-script                    = file("${path.module}/scripts/database-host-shutdown.sh")
  }

  metadata_startup_script = file("${path.module}/scripts/database-host-startup.sh")

  disk {
    auto_delete  = true
    boot         = true
    device_name  = "agora-boot"
    disk_size_gb = 20
    disk_type    = "pd-standard"
    source_image = var.database_cos_image
  }

  # The template references the separately managed disk so machine and boot
  # changes cannot make data-disk replacement part of the template lifecycle.
  disk {
    auto_delete = false
    boot        = false
    device_name = local.database_device_name
    mode        = "READ_WRITE"
    # Global instance templates resolve an existing zonal disk by name.
    source = google_compute_disk.database.name
  }

  network_interface {
    subnetwork = google_compute_subnetwork.production.id
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
    provisioning_model  = "STANDARD"
  }

  service_account {
    email  = google_service_account.runtime["database"].email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = true
    enable_vtpm                 = true
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    google_project_service.workload["compute.googleapis.com"],
    google_service_account_iam_member.foundation_database_act_as,
    google_service_account_iam_member.mig_database_act_as,
  ]
}

resource "google_compute_instance_group_manager" "database" {
  project = google_project.workload.project_id
  zone    = var.database_zone
  name    = "agora-database"

  description        = "Fixed-size stateful group for the production PostgreSQL host."
  base_instance_name = "agora-database"
  target_size        = 1

  version {
    name              = "primary"
    instance_template = google_compute_instance_template.database.self_link_unique
  }

  stateful_disk {
    device_name = local.database_device_name
    delete_rule = "NEVER"
  }

  stateful_internal_ip {
    interface_name = "nic0"
    delete_rule    = "NEVER"
  }

  # Foundation seeds the seven non-secret deployment keys, then deliberately
  # leaves this one field to the protected release workflow. The Google
  # provider's per-instance-config resource creates a new MIG member on its
  # first apply, so it cannot safely attach metadata to this existing member.
  all_instances_config {
    metadata = {
      agora-authentication-database-image                   = ""
      agora-authentication-postgres-backup-password-version = "0"
      agora-authentication-postgres-password-version        = "0"
      agora-database-release-revision                       = ""
      agora-json-keys-database-image                        = ""
      agora-json-keys-postgres-backup-password-version      = "0"
      agora-json-keys-postgres-password-version             = "0"
    }
  }

  update_policy {
    # Never let a metadata or template change trigger an action before its
    # owning protected workflow supplies the reviewed disruption ceiling.
    type                           = "OPPORTUNISTIC"
    minimal_action                 = "REPLACE"
    most_disruptive_allowed_action = "REPLACE"
    max_surge_fixed                = 0
    max_unavailable_fixed          = 1
    replacement_method             = "RECREATE"
  }

  wait_for_instances        = true
  wait_for_instances_status = "STABLE"
  deletion_policy           = "DELETE"

  lifecycle {
    # Routine deployment patches only allInstancesConfig and applies it with a
    # restart-only ceiling. Foundation still owns every other MIG property.
    ignore_changes = [all_instances_config]
  }
}

# The generated instance name and live address are operator-facing outputs.
data "google_compute_instance_group" "database" {
  project = google_project.workload.project_id
  zone    = var.database_zone
  name    = google_compute_instance_group_manager.database.name

  depends_on = [google_compute_instance_group_manager.database]
}

data "google_compute_instance" "database" {
  project = google_project.workload.project_id
  zone    = var.database_zone
  name    = basename(one(data.google_compute_instance_group.database.instances))

  depends_on = [data.google_compute_instance_group.database]
}
