# Cloud Billing exports the billing account's cost data here, once an operator turns the export on
# (docs/runbooks/setup.md#billing-export). The multi-region lets Billing backfill from the start of
# the previous month. Tables never expire, since Billing cannot restore a deleted row.
#
# Billing adds its own service account to the dataset's access list, and the export stops without
# it. Leave `access` unset, so OpenTofu never manages that list and never removes the entry.
resource "google_bigquery_dataset" "billing_export" {
  dataset_id  = "billing_export"
  location    = var.storage_location
  description = "Cloud Billing export of the billing account's cost data."

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["bigquery.googleapis.com"]]
}
