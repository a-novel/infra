# This root prepares storage only. Database activation and disruptive maintenance
# need their own reviewed contract before any operational writer is connected.
locals {
  database = var.database == null ? {} : { host = var.database }
  database_profiles = {
    e2-medium     = { memory_mb = 4096, vcpu = 2 }
    e2-standard-2 = { memory_mb = 8192, vcpu = 2 }
    e2-standard-4 = { memory_mb = 16384, vcpu = 4 }
  }
  database_port = lookup({ json-keys = 5432, authentication = 5433 }, var.service, 0)
}

variable "database" {
  description = "Optional private, idle PostgreSQL host. Supply published network coordinates and a reviewed immutable COS image."
  type = object({
    zone                = string
    subnetwork          = string
    cos_image           = string
    machine_type        = optional(string, "e2-medium")
    disk_size_gb        = optional(number, 50)
    container_cpu       = optional(number, 0.75)
    container_memory_mb = optional(number, 1536)
    max_connections     = optional(number, 50)
  })
  default = null

  validation {
    condition = var.database == null ? true : alltrue([
      can(regex("^${var.region}-[a-z]$", var.database.zone)),
      can(regex("^projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/regions/${var.region}/subnetworks/[a-z][a-z0-9-]*$", var.database.subnetwork)),
      can(regex("^projects/cos-cloud/global/images/cos-[0-9]+(-[0-9]+)+$", var.database.cos_image)),
    ])
    error_message = "Use the selected region's zone/subnet and a pinned COS image, not an image family."
  }

  validation {
    condition = var.database == null ? true : try(alltrue([
      var.database.container_memory_mb >= 512,
      var.database.container_memory_mb % 128 == 0,
      var.database.container_memory_mb <= local.database_profiles[var.database.machine_type].memory_mb - 1024,
      var.database.container_cpu >= 0.25,
      var.database.container_cpu <= local.database_profiles[var.database.machine_type].vcpu - 0.5,
      var.database.disk_size_gb >= 50,
      var.database.disk_size_gb <= 1000,
      var.database.disk_size_gb % 10 == 0,
      var.database.max_connections >= 20,
      var.database.max_connections <= 200,
      floor(var.database.max_connections) == var.database.max_connections,
    ]), false)
    error_message = "Select a reviewed e2 profile, leave 1 GiB and 0.5 vCPU for COS, and use bounded disk/connection capacity."
  }

  validation {
    condition     = var.database == null || var.rollout == null ? true : var.database.subnetwork == var.rollout.subnetwork
    error_message = "The database and configured rollout must use the same published service subnet."
  }
}

resource "google_compute_disk" "database" {
  for_each = local.database

  project                   = var.project_id
  zone                      = each.value.zone
  name                      = "agora-data-${var.service}"
  type                      = "pd-balanced"
  size                      = each.value.disk_size_gb
  physical_block_size_bytes = 4096
  deletion_policy           = "PREVENT"
  labels                    = { component = var.service, role = "database-data" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_instance_template" "database" {
  for_each = local.database

  project        = var.project_id
  region         = var.region
  name_prefix    = "agora-database-${var.service}-"
  machine_type   = each.value.machine_type
  can_ip_forward = false
  tags           = ["agora-database-${var.service}"]
  labels         = { component = var.service, role = "database" }

  metadata = {
    agora-database-service             = var.service
    agora-database-data-disk-id        = google_compute_disk.database[each.key].disk_id
    agora-database-container-cpu       = tostring(each.value.container_cpu)
    agora-database-container-memory-mb = tostring(each.value.container_memory_mb)
    agora-database-data-disk-size-gb   = tostring(each.value.disk_size_gb)
    agora-database-max-connections     = tostring(each.value.max_connections)
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
    shutdown-script                    = file("${path.module}/../../assets/database-host/shutdown.sh")
  }
  metadata_startup_script = file("${path.module}/../../assets/database-host/startup.sh")

  disk {
    auto_delete  = true
    boot         = true
    device_name  = "agora-boot"
    disk_size_gb = 20
    disk_type    = "pd-balanced"
    source_image = each.value.cos_image
  }
  disk {
    auto_delete = false
    boot        = false
    device_name = "agora-data"
    mode        = "READ_WRITE"
    # Global templates resolve the separately owned zonal disk by name.
    source = google_compute_disk.database[each.key].name
  }
  network_interface {
    subnetwork = each.value.subnetwork
  }
  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
    provisioning_model  = "STANDARD"
  }
  service_account {
    email  = google_service_account.database[each.key].email
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
  depends_on = [google_service_account_iam_member.database_attachment]
}

resource "google_compute_instance_group_manager" "database" {
  for_each = local.database

  project            = var.project_id
  zone               = each.value.zone
  name               = "agora-database-${var.service}"
  base_instance_name = "agora-database-${var.service}"
  target_size        = 1
  deletion_policy    = "PREVENT"

  version {
    name              = "primary"
    instance_template = google_compute_instance_template.database[each.key].self_link_unique
  }
  stateful_disk {
    device_name = "agora-data"
    delete_rule = "NEVER"
  }
  stateful_internal_ip {
    interface_name = "nic0"
    delete_rule    = "NEVER"
  }
  all_instances_config {
    metadata = {
      "agora-${var.service}-database-image"                   = ""
      "agora-${var.service}-postgres-password-version"        = "0"
      "agora-${var.service}-postgres-backup-password-version" = "0"
      agora-database-release-revision                         = ""
    }
  }
  update_policy {
    type                           = "OPPORTUNISTIC"
    minimal_action                 = "REPLACE"
    most_disruptive_allowed_action = "REPLACE"
    max_surge_fixed                = 0
    max_unavailable_fixed          = 1
    replacement_method             = "RECREATE"
  }
  wait_for_instances        = true
  wait_for_instances_status = "STABLE"

  lifecycle {
    prevent_destroy = true
  }
}

data "google_compute_instance_group" "database" {
  for_each  = local.database
  self_link = google_compute_instance_group_manager.database[each.key].instance_group
}

data "google_compute_instance" "database" {
  for_each  = local.database
  self_link = one(data.google_compute_instance_group.database[each.key].instances)
}

output "database" {
  description = "Versioned idle-host coordinates; STABLE is not PostgreSQL health or activation evidence."
  value = var.database == null ? null : {
    schema_version  = 1
    project_id      = var.project_id
    service         = var.service
    zone            = var.database.zone
    service_account = google_service_account.database["host"].email
    group           = google_compute_instance_group_manager.database["host"].name
    disk            = google_compute_disk.database["host"].name
    disk_id         = google_compute_disk.database["host"].disk_id
    private_ip      = data.google_compute_instance.database["host"].network_interface[0].network_ip
    port            = local.database_port
  }
  depends_on = [
    google_secret_manager_secret_iam_member.database,
    google_artifact_registry_repository_iam_member.database,
    google_compute_disk_resource_policy_attachment.database,
  ]
}
