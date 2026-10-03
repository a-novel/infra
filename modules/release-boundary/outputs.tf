output "release" {
  description = "Identity and custody coordinates. Shared-zone schema 2 requires zone-aware consumers before activation."
  value = merge({
    schema_version             = var.zone == null ? 1 : 2
    service_account            = google_service_account.release.email
    workload_identity_provider = google_iam_workload_identity_pool_provider.release.name
    environment                = local.release_environment
    state                      = local.release_storage.state
    receipts                   = local.release_storage.receipts
    }, var.zone == null ? {} : {
    service    = var.labels.service
    zone       = var.zone
    project_id = var.project_id
  })
}
