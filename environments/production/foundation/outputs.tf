output "region" {
  description = "Production Google Cloud region."
  value       = var.region
}

output "workload_project_id" {
  description = "Replaceable production workload project ID."
  value       = google_project.workload.project_id
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
    # The subnet whose workloads leave for the internet, through Cloud NAT.
    egress_subnet_id = google_compute_subnetwork.egress.id
  }
}

output "nat_address" {
  description = "The one address production's internet egress leaves from, which the providers' IP allowlists name."
  value       = google_compute_address.nat.address
}

output "cluster" {
  description = "The production cluster, which the Kubernetes roots reach through its DNS endpoint."
  value = {
    name         = google_container_cluster.production.name
    location     = google_container_cluster.production.location
    dns_endpoint = one(one(google_container_cluster.production.control_plane_endpoints_config).dns_endpoint_config).endpoint
    # The nodes' range, which holds the control plane's internal endpoint, and Google's restricted
    # API addresses, for the network policies of pods that call either.
    node_range        = var.cluster_ranges.nodes
    google_api_ranges = sort(tolist(local.restricted_google_api_ranges))
    # Each service's PostgreSQL image, pinned by digest in its private repository.
    database_images = local.database_image
    # Where the add-ons pull each public registry's images from, by its host.
    image_registries = { for name, repository in google_artifact_registry_repository.cluster_upstream : trimprefix(local.cluster_image_upstreams[name], "https://") => repository.registry_uri }
  }
}

output "cluster_nat_address" {
  description = "The address the cluster's internet egress leaves from, which the providers' IP allowlists name beside nat_address."
  value       = google_compute_address.cluster_nat.address
}

output "database_hosts" {
  description = "Service-owned PostgreSQL hosts and disk incarnations for release and recovery."
  value = {
    for service, host in local.database_hosts : service => {
      data_disk = {
        name    = google_compute_disk.database[service].name
        id      = google_compute_disk.database[service].disk_id
        size_gb = google_compute_disk.database[service].size
        type    = google_compute_disk.database[service].type
      }
      instance_group_manager = google_compute_instance_group_manager.database[service].name
      instance_name          = data.google_compute_instance.database[service].name
      machine_type           = host.capacity.machine_type
      port                   = host.port
      private_ip             = one(data.google_compute_instance.database[service].network_interface).network_ip
      # The backup repository VM's address, which the database host trusts.
      repository_ip = try(google_compute_address.pgbackrest_repository[host.component].address, null)
      # The host-credentials image both of the service's hosts run, from its private tooling repository.
      credentials_image = try(local.host_credentials_image[host.component], null)
      service_account   = google_service_account.runtime[host.identity].email
      zone              = var.database_zone
    }
  }
}

output "cloud_run_cpu_quotas" {
  description = "Regional Cloud Run CPU ceiling per trust zone, in milli-vCPU. Service roots check their instance caps against it."
  value = merge(
    { private = var.cloud_run_cpu_quota_millicpu },
    { for zone in keys(local.shell_projects) : zone => var.shell_cloud_run_quota.cpu_millicpu },
  )
}

output "sentry_ingest_host" {
  description = "Sentry's ingest host. Error events and each project's OTLP endpoint share it."
  value       = var.sentry_ingest_host
}
