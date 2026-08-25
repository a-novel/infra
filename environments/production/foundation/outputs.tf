output "region" {
  description = "Production Google Cloud region."
  value       = var.region
}

output "workload_project_id" {
  description = "Replaceable production workload project ID."
  value       = google_project.workload.project_id
}

output "workload_project_number" {
  description = "Immutable project number used by service agents and budget scoping."
  value       = google_project.workload.number
}

output "network" {
  description = "Direct VPC network and subnet consumed by production resources."
  value = {
    name         = google_compute_network.production.name
    network_id   = google_compute_network.production.id
    subnet       = google_compute_subnetwork.production.name
    subnet_id    = google_compute_subnetwork.production.id
    subnet_cidr  = google_compute_subnetwork.production.ip_cidr_range
    network_tags = local.network_tags
  }
}

output "artifact_registry" {
  description = "Regional immutable Docker repository used by verified release promotion."
  value = {
    repository_id = google_artifact_registry_repository.production.repository_id
    registry_uri  = google_artifact_registry_repository.production.registry_uri
  }
}

output "database_host" {
  description = "Private stateful PostgreSQL host identifiers for operator verification and recovery records."
  value = {
    data_disk = {
      name    = google_compute_disk.database.name
      size_gb = google_compute_disk.database.size
      type    = google_compute_disk.database.type
    }
    instance_group_manager = google_compute_instance_group_manager.database.name
    instance_name          = data.google_compute_instance.database.name
    machine_type           = var.database_machine_type
    ports                  = local.database_ports
    private_ip             = one(data.google_compute_instance.database.network_interface).network_ip
    zone                   = var.database_zone
  }
}

output "runtime_service_accounts" {
  description = "Keyless service-account emails for workload and operational trust boundaries."
  value = {
    for name, account in google_service_account.runtime : name => account.email
  }
}

output "root_name" {
  description = "Stable root identifier used by repository validation."
  value       = local.root_name
}
