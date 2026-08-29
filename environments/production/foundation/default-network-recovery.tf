# Project imports skip the provider's create-only default-network cleanup.
# This address puts the audited empty VPC behind the reviewed deletion gate.
resource "google_compute_network" "default_adoption" {
  count = var.adopt_default_network && !var.recovery_mode ? 1 : 0

  project = google_project.workload.project_id
  name    = "default"

  auto_create_subnetworks = true
  deletion_policy         = "DELETE"

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
}

import {
  for_each = var.adopt_default_network && !var.recovery_mode ? toset([var.workload_project_id]) : toset([])

  to = google_compute_network.default_adoption[0]
  id = "projects/${each.value}/global/networks/default"
}
