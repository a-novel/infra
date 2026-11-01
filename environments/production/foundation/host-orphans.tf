# The database host groups left their stateful addresses reserved (`delete_rule = NEVER`), and the
# rollouts their pre-rollout snapshots, outside any state (a-novel/infra#1208). Only the deploy
# identity may delete them, so this adopts them, and the next pull request deletes them with the
# old network: each address before its subnet. Their configuration only adopts them.
variable "orphan_addresses" {
  description = "Internal addresses the retired database host groups left reserved, by name, with their IP."
  type        = map(string)
  default     = {}
}

variable "orphan_snapshots" {
  description = "Pre-rollout snapshots of the retired database hosts, by name, with their service."
  type        = map(string)
  default     = {}
}

import {
  for_each = var.orphan_addresses

  to = google_compute_address.orphan[each.key]
  id = "projects/${var.workload_project_id}/regions/${var.region}/addresses/${each.key}"
}

resource "google_compute_address" "orphan" {
  for_each = var.orphan_addresses

  project      = google_project.workload.project_id
  region       = var.region
  name         = each.key
  address      = each.value
  address_type = "INTERNAL"
  purpose      = "GCE_ENDPOINT"
  subnetwork   = google_compute_subnetwork.production.id

  lifecycle {
    ignore_changes = all
  }
}

import {
  for_each = var.orphan_snapshots

  to = google_compute_snapshot.pre_rollout[each.key]
  id = "projects/${var.workload_project_id}/global/snapshots/${each.key}"
}

resource "google_compute_snapshot" "pre_rollout" {
  for_each = var.orphan_snapshots

  project     = google_project.workload.project_id
  name        = each.key
  source_disk = "projects/${var.workload_project_id}/zones/europe-west1-d/disks/agora-data-${each.value}"

  lifecycle {
    ignore_changes = all
  }
}
