output "jobs" {
  description = "Selected job identities and images; a non-null execution token identifies the native migration completion required by routine release."
  value = {
    schema_version = 1
    project_id     = var.project_id
    service        = var.service
    region         = var.region
    definitions = { for role, job in google_cloud_run_v2_job.application : role => {
      name            = job.name
      uid             = job.uid
      image           = job.template[0].template[0].containers[0].image
      execution_token = job.run_execution_token
    } }
  }
}
