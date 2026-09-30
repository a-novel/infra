# Read only through private plan custody after convergence. Expected metadata comes
# from configuration; the data source supplies the reconciled member's identity.
output "native_bringup" {
  description = "Private targets for guarded host bring-up; not application or backup readiness."
  sensitive   = true
  value = !local.native_host_bringup ? null : {
    project     = var.project_id
    zone        = var.database.zone
    group       = google_compute_instance_group_manager.database["host"].name
    template    = google_compute_instance_template.database["host"].self_link
    template_id = google_compute_instance_template.database["host"].numeric_id
    image       = var.pgbackrest_repository.runtime.server_image
    database = {
      name        = data.google_compute_instance.database["host"].name
      instance_id = data.google_compute_instance.database["host"].instance_id
      metadata = merge(google_compute_instance_template.database["host"].metadata,
      google_compute_instance_group_manager.database["host"].all_instances_config[0].metadata)
    }
    repository = {
      name        = google_compute_instance.repository["host"].name
      instance_id = google_compute_instance.repository["host"].instance_id
      metadata    = google_compute_instance.repository["host"].metadata
    }
  }
}
