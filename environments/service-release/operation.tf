variable "release_operation" {
  description = "Optional established-release predecessor and distinct rollout UUID; null exports no executable operation."
  type = object({
    predecessor        = string
    rollout_request_id = string
  })
  default = null

  validation {
    condition = var.release_operation == null ? true : try(
      var.rollout != null &&
      can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.release_operation.predecessor)) &&
      var.release_operation.predecessor != var.rollout.release_id &&
      can(regex("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", var.release_operation.rollout_request_id)) &&
      var.release_operation.rollout_request_id != "00000000-0000-0000-0000-000000000000" &&
      var.release_operation.rollout_request_id != var.rollout.request_id, false
    )
    error_message = "A guarded release needs API pins, a different established predecessor and a distinct nonzero rollout UUID."
  }
}

output "release_operation" {
  description = "Prepared native operation for independent protected approval after convergence; not evidence of execution or readiness."
  sensitive   = true
  value = var.release_operation == null || var.rollout == null ? null : {
    schema_version        = 1
    service               = var.service
    project_id            = var.project_id
    project_number        = var.rollout.project_number
    management_project_id = var.management_project_id
    region                = var.region
    state_bucket          = var.state_bucket
    predecessor           = var.release_operation.predecessor
    rollout_request_id    = var.release_operation.rollout_request_id
    request               = local.release_request
    foundation            = var.foundation
    foundation_json       = var.foundation_json
    images                = var.images
    secret_versions       = var.secret_versions
    rollout               = { image = var.rollout.image }
    jobs = { for role, job in google_cloud_run_v2_job.application : role => {
      name = "projects/${var.rollout.project_number}/locations/${var.region}/jobs/${job.name}"
      uid  = job.uid
      template = {
        taskCount   = job.template[0].task_count
        parallelism = job.template[0].parallelism
        template = {
          serviceAccount       = job.template[0].template[0].service_account
          executionEnvironment = job.template[0].template[0].execution_environment
          timeout              = job.template[0].template[0].timeout
          maxRetries           = job.template[0].template[0].max_retries
          containers = [for container in job.template[0].template[0].containers : {
            name      = container.name
            image     = container.image
            resources = { limits = container.resources[0].limits }
            env = [for env in container.env : merge({ name = env.name },
              length(env.value_source) == 0 ? { value = env.value } : {},
              length(env.value_source) > 0 ? { valueSource = { secretKeyRef = env.value_source[0].secret_key_ref[0] } } : {}
            )]
          }]
          vpcAccess = {
            egress = job.template[0].template[0].vpc_access[0].egress
            networkInterfaces = [for interface in job.template[0].template[0].vpc_access[0].network_interfaces : {
              network = interface.network, subnetwork = interface.subnetwork, tags = interface.tags
            }]
          }
        }
      }
    } }
  }
}
