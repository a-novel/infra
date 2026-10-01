module "project" {
  source = "../project-shell"

  project_id                 = var.project_id
  billing_account_id         = var.billing_account_id
  organization_id            = var.organization_id
  folder_id                  = var.folder_id
  labels                     = var.labels
  foundation_service_account = var.foundation_service_account
  plan_service_account       = var.plan_service_account
}
