output "jobs" {
  description = "Selected-service job identities and configured images; execution must inspect the live template and record its own operation."
  value = {
    schema_version = 1
    project_id     = var.runtime.project_id
    service        = var.runtime.service
    region         = var.runtime.region
    definitions = { for role, job in google_cloud_run_v2_job.application : role => {
      name  = job.name
      uid   = job.uid
      image = job.template[0].template[0].containers[0].image
    } }
  }
}
