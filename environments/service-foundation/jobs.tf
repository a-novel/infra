variable "manage_job_access" {
  description = "Protected opt-in after application jobs exist in service-release state; this input is not bootstrap or execution evidence."
  type        = bool
  default     = false
  nullable    = false
}

module "job_access" {
  source = "../../modules/service-job-access"
  count  = var.manage_job_access ? 1 : 0

  runtime                    = local.runtime
  foundation_service_account = local.foundation_service_account
  state_bucket               = var.state_bucket
}
