locals {
  shared_database_coordinates = {
    for service in keys(var.service_release_zones) : service => {
      schema_version = 2
      service        = service
      project_id     = google_project.workload.project_id
      zone           = var.database_zone
      private_ip     = one(data.google_compute_instance.database[replace(service, "-", "_")].network_interface).network_ip
      port           = local.database_ports[replace(service, "-", "_")]
    } if contains(["json-keys", "authentication"], service)
  }
  shared_database_json = { for service, coordinates in local.shared_database_coordinates : service => jsonencode(coordinates) }
}

# Existing foundation authority reads this prefix. Release identities consume
# only their service foundation's approved runtime document.
resource "google_storage_bucket_object" "database_coordinates" {
  for_each = local.shared_database_json

  bucket          = "${var.management_project_id}-${data.google_project.management[0].number}-tofu-state"
  name            = "foundation/database-coordinates/production/${google_project.workload.project_id}/${each.key}/${sha256(each.value)}.json"
  content         = each.value
  content_type    = "application/json"
  cache_control   = "private, no-store"
  deletion_policy = "ABANDON"

}

output "database_coordinates" {
  description = "Minimal existing-database references; approve exact generations only after foundation convergence."
  value = { for service, document in google_storage_bucket_object.database_coordinates : service => {
    schema_version = 2
    bucket         = document.bucket
    object         = document.name
    generation     = document.generation
    sha256         = sha256(local.shared_database_json[service])
  } }
}
