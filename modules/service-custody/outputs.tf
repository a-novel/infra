output "release" {
  description = "Private state and operation-evidence coordinates for native deployment."
  value = merge({
    schema_version = var.zone == null ? 1 : 2
    state          = local.release_storage.state
    receipts       = local.release_storage.receipts
    }, var.zone == null ? {} : {
    service    = var.labels.service
    zone       = var.zone
    project_id = var.project_id
  })
}
