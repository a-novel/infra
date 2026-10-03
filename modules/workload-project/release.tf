module "release" {
  source = "../release-boundary"

  project_id           = module.project.project_id
  labels               = var.labels
  management           = var.management
  plan_service_account = var.plan_service_account
  retirement           = var.retirement
}
