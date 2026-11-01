output "region" {
  description = "Production Google Cloud region."
  value       = var.region
}

output "workload_project_id" {
  description = "Replaceable production workload project ID."
  value       = google_project.workload.project_id
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
    # Where the add-ons pull each public registry's images from, by its host.
    image_registries = { for name, repository in google_artifact_registry_repository.cluster_upstream : replace(name, "-", ".") => repository.registry_uri }
  }
}

output "cluster_nat_address" {
  description = "The address the cluster's internet egress leaves from, which the providers' IP allowlists name."
  value       = google_compute_address.cluster_nat.address
}
