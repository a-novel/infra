# The first cluster, in europe-west1, left JSON Keys' two database disks behind when it was deleted
# (a-novel/.github#522). They held no production data, and OpenTofu deletes only what its state
# holds, so this root imports them as they are and the next change deletes them.
import {
  for_each = var.leftover_disks

  to = google_compute_disk.leftover[each.key]
  id = "projects/${google_project.workload.project_id}/zones/${each.value}/disks/${each.key}"
}

resource "google_compute_disk" "leftover" {
  for_each = var.leftover_disks

  project = google_project.workload.project_id
  name    = each.key
  zone    = each.value

  # GKE created them; the import changes nothing.
  lifecycle {
    ignore_changes = all
  }
}
