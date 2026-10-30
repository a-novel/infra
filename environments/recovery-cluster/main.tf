data "terraform_remote_state" "bootstrap" {
  backend = "gcs"
  config = {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "bootstrap"
  }
}

data "google_project" "drill" {
  project_id = var.recovery.project
}

locals {
  region = "europe-west9"
  zone   = "europe-west9-a"
  ranges = { nodes = "10.92.0.0/24", pods = "10.92.16.0/20", services = "10.92.32.0/22" }

  # Google's restricted API addresses are the only destinations outside the cluster. The private
  # zones below resolve the domains the nodes, the caches and Barman reach to them.
  google_api_ranges = ["199.36.153.4/30", "34.126.0.0/18"]
  google_domains    = ["googleapis.com", "gcr.io", "pkg.dev"]
  upstreams         = { ghcr-io = "https://ghcr.io", quay-io = "https://quay.io" }
}

# The drill restores production data, so the network reaches nothing but Google's APIs, through
# private routes.
resource "google_compute_network" "drill" {
  project                         = var.recovery.project
  name                            = "recovery"
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = true
}

resource "google_compute_subnetwork" "drill" {
  project                  = var.recovery.project
  region                   = local.region
  name                     = "recovery"
  network                  = google_compute_network.drill.id
  ip_cidr_range            = local.ranges.nodes
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = local.ranges.pods
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = local.ranges.services
  }
}

resource "google_compute_route" "google_apis" {
  for_each = toset(local.google_api_ranges)

  project          = var.recovery.project
  name             = "recovery-google-${replace(replace(each.key, ".", "-"), "/", "-")}"
  network          = google_compute_network.drill.id
  dest_range       = each.key
  next_hop_gateway = "default-internet-gateway"
}

resource "google_compute_firewall" "allow_google_apis" {
  project            = var.recovery.project
  name               = "recovery-allow-google-apis"
  network            = google_compute_network.drill.name
  direction          = "EGRESS"
  priority           = 800
  destination_ranges = local.google_api_ranges

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

# Nodes and pods talk to each other, and the nodes reach the control plane inside the node range.
resource "google_compute_firewall" "allow_internal" {
  project            = var.recovery.project
  name               = "recovery-allow-internal"
  network            = google_compute_network.drill.name
  direction          = "EGRESS"
  priority           = 800
  destination_ranges = [local.ranges.nodes, local.ranges.pods]

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "deny_egress" {
  project            = var.recovery.project
  name               = "recovery-deny-egress"
  network            = google_compute_network.drill.name
  direction          = "EGRESS"
  priority           = 1200
  destination_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }
}

resource "google_dns_managed_zone" "google" {
  for_each = toset(local.google_domains)

  project    = var.recovery.project
  name       = "recovery-${replace(each.key, ".", "-")}"
  dns_name   = "${each.key}."
  visibility = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.drill.id
    }
  }
}

resource "google_dns_record_set" "google" {
  for_each = google_dns_managed_zone.google

  project      = var.recovery.project
  managed_zone = each.value.name
  name         = "*.${each.key}."
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"]
}

# Artifact Registry fetches each upstream itself, so the nodes pull without leaving the network.
resource "google_artifact_registry_repository" "upstream" {
  for_each = local.upstreams

  project       = var.recovery.project
  location      = local.region
  repository_id = each.key
  description   = "Pull-through cache of ${each.value} for the drill."
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    description = each.value

    docker_repository {
      custom_repository {
        uri = each.value
      }
    }
  }
}

resource "google_service_account" "nodes" {
  project      = var.recovery.project
  account_id   = "recovery-nodes"
  display_name = "Recovery drill nodes"
}

resource "google_project_iam_member" "nodes" {
  project = var.recovery.project
  role    = "roles/container.defaultNodeServiceAccount"
  member  = google_service_account.nodes.member
}

# The nodes pull every image from the drill's own caches, by the digests production pins, so the
# drill reads nothing in production's registries.
resource "google_artifact_registry_repository_iam_member" "nodes" {
  for_each = google_artifact_registry_repository.upstream

  project    = each.value.project
  location   = each.value.location
  repository = each.value.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.nodes.member
}

# Production's cluster without its database rules: one zone, one node, and gone with the drill.
resource "google_container_cluster" "drill" {
  project    = var.recovery.project
  name       = "recovery"
  location   = local.zone
  network    = google_compute_network.drill.id
  subnetwork = google_compute_subnetwork.drill.id

  networking_mode   = "VPC_NATIVE"
  datapath_provider = "ADVANCED_DATAPATH"

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # As in production, CI reaches the control plane only through its DNS endpoint.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
  }

  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false
  }

  workload_identity_config {
    workload_pool = "${var.recovery.project}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]

    managed_prometheus {
      enabled = false
    }
  }

  remove_default_node_pool = true
  initial_node_count       = 1

  node_config {
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  deletion_protection = false
  lifecycle {
    ignore_changes = [node_config]
  }

  depends_on = [google_project_iam_member.nodes]
}

# One node holds GKE's own pods, the operators and every restored database at production's sizes.
resource "google_container_node_pool" "drill" {
  project    = var.recovery.project
  location   = google_container_cluster.drill.location
  cluster    = google_container_cluster.drill.name
  name       = "drill"
  node_count = 1

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = "e2-standard-8"
    image_type      = "COS_CONTAINERD"
    disk_type       = "pd-balanced"
    disk_size_gb    = 30
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    metadata        = { disable-legacy-endpoints = "true" }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}

# Each restored database's Kubernetes service account, which CloudNativePG names after its Cluster,
# reads its own service's backups and changes nothing. Destroying the drill takes the grants back.
resource "google_storage_bucket_iam_member" "backups" {
  for_each = var.recovery.services

  bucket = data.terraform_remote_state.bootstrap.outputs.barman_buckets[each.key]
  role   = data.terraform_remote_state.bootstrap.outputs.barman_reader_role
  member = "principal://iam.googleapis.com/projects/${data.google_project.drill.number}/locations/global/workloadIdentityPools/${var.recovery.project}.svc.id.goog/subject/ns/${each.key}/sa/drill"

  # The workload identity pool exists once the cluster does.
  depends_on = [google_container_cluster.drill]
}

output "cluster" {
  description = "The drill cluster, which the recovery-database root restores into: its DNS endpoint and each upstream registry's cache, by host."
  value = {
    dns_endpoint     = one(one(google_container_cluster.drill.control_plane_endpoints_config).dns_endpoint_config).endpoint
    image_registries = { for name, repository in google_artifact_registry_repository.upstream : trimprefix(local.upstreams[name], "https://") => repository.registry_uri }
  }
}
