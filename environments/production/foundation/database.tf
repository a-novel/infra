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
    genai          = 5434
  }

  database_hosts = {
    for service, port in local.database_ports : service => {
      component = replace(service, "_", "-")
      port      = port
      identity  = "${service}_database"
      capacity  = var.database_capacity[replace(service, "_", "-")]
    }
  }

  # A probe is a query its host runs every five minutes, logging the one line it returns for a
  # log-based metric in the service root. GenAI's purge deletes the oldest expired generations
  # first, every 10 seconds, so the oldest one left shows how far it lags. Its retention index
  # answers in one read, however large the backlog.
  database_probes = {
    genai = "SELECT 'oldest_expired_seconds=' || coalesce(floor(extract(epoch FROM now() - min(expires_at))), 0) FROM generations WHERE expires_at < now()"
  }

  # COS runs cloud-init at every boot, which writes the probe's units and starts its timer.
  database_probe_user_data = { for component, query in local.database_probes : component => "#cloud-config\n${yamlencode({
    ssh_deletekeys = false
    write_files = [
      {
        path        = "/etc/systemd/system/a-novel-database-probe.service"
        permissions = "0644"
        content     = <<-EOT
          [Unit]
          Description=Agora ${component} database probe
          Requires=docker.service
          After=docker.service

          [Service]
          Type=oneshot
          TimeoutStartSec=60
          ExecStart=/usr/bin/docker exec --user postgres agora-postgres-${component} psql --no-psqlrc --quiet --tuples-only --no-align --set=ON_ERROR_STOP=1 --username=agora_${replace(component, "-", "_")} --dbname=agora_${replace(component, "-", "_")} "--command=${query}"
        EOT
      },
      {
        path        = "/etc/systemd/system/a-novel-database-probe.timer"
        permissions = "0644"
        content     = <<-EOT
          [Unit]
          Description=Agora ${component} database probe, every five minutes

          [Timer]
          OnCalendar=*:0/5
        EOT
      },
    ]
    runcmd = [["systemctl", "daemon-reload"], ["systemctl", "start", "a-novel-database-probe.timer"]]
  })}" }
}

check "database_capacity_matches_hosts" {
  assert {
    condition     = sort(keys(var.database_capacity)) == sort([for host in local.database_hosts : host.component])
    error_message = "database_capacity must size exactly the services that have a database host."
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
    condition = alltrue([for host in local.database_hosts :
      host.capacity.container_memory_mb <= local.database_machine_profiles[host.capacity.machine_type].memory_mb - 1024
    ])
    error_message = "Database container limits must leave at least 1 GiB of host memory."
  }
}

check "database_container_cpu_headroom" {
  assert {
    condition = alltrue([for host in local.database_hosts :
      host.capacity.container_cpu <= local.database_machine_profiles[host.capacity.machine_type].vcpu - 0.5
    ])
    error_message = "Database container limits must leave at least 0.5 vCPU for the host."
  }
}

check "database_cpu_quota" {
  assert {
    condition = var.compute_cpu_quota >= sum([for host in local.database_hosts :
      local.database_machine_profiles[host.capacity.machine_type].vcpu
    ])
    error_message = "The regional Compute CPU quota must fit every database VM."
  }
}

resource "google_compute_disk" "database" {
  for_each = local.database_hosts

  project = google_project.workload.project_id
  zone    = var.database_zone
  name    = "agora-data-${each.value.component}"

  type                      = "pd-balanced"
  size                      = each.value.capacity.data_disk_size_gb
  physical_block_size_bytes = 4096
  description               = "Preserved PostgreSQL data for ${each.value.component}."

  labels = merge(local.labels, { role = "database-data", component = each.value.component })

  deletion_policy = "PREVENT"

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
  lifecycle {
    prevent_destroy = true
    # A disk recreated from a snapshot keeps this name; ignoring its source stops a plan from
    # replacing the protected disk.
    ignore_changes = [snapshot]
  }
}

resource "google_compute_instance_template" "database" {
  for_each = local.database_hosts

  project     = google_project.workload.project_id
  region      = var.region
  name_prefix = "agora-database-${each.value.component}-"

  description          = "Immutable Container-Optimized OS template for the production PostgreSQL host."
  instance_description = "One-member private PostgreSQL data plane."
  machine_type         = each.value.capacity.machine_type
  can_ip_forward       = false

  tags   = [local.network_tags[each.value.identity]]
  labels = merge(local.labels, { role = "database", component = each.value.component })

  metadata = merge({
    agora-database-service             = each.value.component
    agora-database-port                = tostring(each.value.port)
    agora-database-name                = "agora_${each.key}"
    agora-database-data-disk-id        = google_compute_disk.database[each.key].disk_id
    agora-database-container-cpu       = tostring(each.value.capacity.container_cpu)
    agora-database-container-memory-mb = tostring(each.value.capacity.container_memory_mb)
    agora-database-data-disk-size-gb   = tostring(each.value.capacity.data_disk_size_gb)
    agora-database-max-connections     = tostring(each.value.capacity.max_connections)
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
    shutdown-script                    = file("${path.module}/../../../modules/database-runtime/files/shutdown.sh")
  }, contains(keys(local.database_probe_user_data), each.value.component) ? { user-data = local.database_probe_user_data[each.value.component] } : {})

  # A new startup script replaces the host template, so it waits for the service's planned downtime.
  metadata_startup_script = contains(keys(var.native_backups), each.value.component) ? module.native_backup[each.value.component].startup_script : file("${path.module}/../../../modules/database-runtime/files/startup.sh")

  disk {
    auto_delete  = true
    boot         = true
    device_name  = "agora-boot"
    disk_size_gb = 20
    disk_type    = "pd-balanced"
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
    source = google_compute_disk.database[each.key].name
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
    email  = google_service_account.runtime[each.value.identity].email
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

# Each database image probes PostgreSQL with `pg_isready` every second, and COS logs every probe as
# three Docker events. The exclusion keeps a failed probe's `exec_die` line, the start of every other
# `docker exec`, and the container lifecycle events.
resource "google_logging_project_exclusion" "database_health_probes" {
  project = google_project.workload.project_id

  name        = "successful-database-health-probes"
  description = "Exclude the Docker exec events of successful pg_isready probes on the database hosts."
  disabled    = false
  filter      = <<-EOT
    resource.type="gce_instance"
    log_id("cos_system")
    jsonPayload._SYSTEMD_UNIT="docker-events-collector-fluent-bit.service"
    jsonPayload.MESSAGE=~" container (exec_(create|start): pg_isready |exec_die .* exitCode=0,)"
  EOT

  depends_on = [google_project_service.workload["logging.googleapis.com"]]
}

resource "google_compute_instance_group_manager" "database" {
  for_each = local.database_hosts

  project = google_project.workload.project_id
  zone    = var.database_zone
  name    = "agora-database-${each.value.component}"

  description        = "Fixed-size stateful group for the production PostgreSQL host."
  base_instance_name = "agora-database-${each.value.component}"
  target_size        = 1

  version {
    name              = "primary"
    instance_template = google_compute_instance_template.database[each.key].self_link_unique
  }

  stateful_disk {
    device_name = local.database_device_name
    delete_rule = "NEVER"
  }

  stateful_internal_ip {
    interface_name = "nic0"
    delete_rule    = "NEVER"
  }

  all_instances_config {
    metadata = {
      "agora-${each.value.component}-database-image"       = try(local.database_image[each.value.component], "")
      "agora-${each.value.component}-app-password-version" = try(var.database_releases[each.value.component].app_password_version, "0")
      agora-database-release-revision                      = try(var.database_releases[each.value.component].revision, "")
    }
  }

  update_policy {
    # Merging a template or metadata change restarts nothing. The deploy's rollout job restarts
    # each host during its service's planned downtime.
    type                           = "OPPORTUNISTIC"
    minimal_action                 = "REPLACE"
    most_disruptive_allowed_action = "REPLACE"
    max_surge_fixed                = 0
    max_unavailable_fixed          = 1
    replacement_method             = "RECREATE"
  }

  wait_for_instances        = true
  wait_for_instances_status = "STABLE"
  deletion_policy           = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  # The group URL becomes known at creation and stays stable during template maintenance.
  database_group_names = {
    for service, group in google_compute_instance_group_manager.database : service => basename(group.instance_group)
  }
}

# The generated instance name and live address are operator-facing outputs.
data "google_compute_instance_group" "database" {
  for_each = local.database_hosts

  project = google_project.workload.project_id
  zone    = var.database_zone
  name    = local.database_group_names[each.key]
}

data "google_compute_instance" "database" {
  for_each = local.database_hosts

  project = google_project.workload.project_id
  zone    = var.database_zone
  name    = basename(one(data.google_compute_instance_group.database[each.key].instances))
}
