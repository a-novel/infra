# The production cluster (a-novel/.github#523). It is zonal, so the billing account's free tier
# covers its management fee, and its nodes span two zones. It holds no workload yet.
resource "google_container_cluster" "production" {
  project        = google_project.workload.project_id
  name           = "a-novel-production"
  location       = var.cluster.zones[0]
  node_locations = slice(var.cluster.zones, 1, length(var.cluster.zones))

  network         = google_compute_network.cluster.id
  subnetwork      = google_compute_subnetwork.cluster.id
  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Dataplane V2 enforces network policies, the FQDN ones included.
  datapath_provider          = "ADVANCED_DATAPATH"
  enable_fqdn_network_policy = true

  # Nodes have no external address and reach the control plane on its internal endpoint. Everyone
  # else reaches it only through its DNS endpoint, which IAM and the perimeter guard.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
  }

  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  # No address range is authorized, so no one could reach an external IP endpoint even if one came
  # back.
  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false
  }

  workload_identity_config {
    workload_pool = "${google_project.workload.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  # Upgrades start only early on Tuesday, Wednesday and Thursday mornings, UTC: 18 hours a week,
  # above GKE's minimum of 48 hours in 32 days.
  maintenance_policy {
    recurring_window {
      start_time = "2026-11-03T01:00:00Z"
      end_time   = "2026-11-03T07:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=TU,WE,TH"
    }
  }

  # Grafana takes every signal through Alloy, so Google collects only the system components.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]

    managed_prometheus {
      enabled = false
    }
  }

  # GKE creates a default pool before removing it, so even that pool runs as the node identity. Its
  # settings never apply again, so changes to them are ignored rather than replacing the cluster.
  remove_default_node_pool = true
  initial_node_count       = 1

  node_config {
    service_account = google_service_account.runtime["cluster_nodes"].email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  deletion_protection = true
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [node_config]
  }
}

resource "google_container_node_pool" "general" {
  project  = google_project.workload.project_id
  location = google_container_cluster.production.location
  cluster  = google_container_cluster.production.name
  name     = "general"

  # One node per zone to start; the autoscaler adds the third.
  initial_node_count = 1

  autoscaling {
    total_min_node_count = var.cluster.min_nodes
    total_max_node_count = var.cluster.max_nodes
    location_policy      = "BALANCED"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # An upgrade adds a node before it drains one, so the databases' primaries and replicas always
  # have two nodes to sit on.
  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type    = var.cluster.machine_type
    image_type      = "COS_CONTAINERD"
    disk_type       = "pd-balanced"
    disk_size_gb    = 50
    service_account = google_service_account.runtime["cluster_nodes"].email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    metadata        = { disable-legacy-endpoints = "true" }

    # Pods see GKE's metadata server, which hands each one its own identity, never the node's.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
