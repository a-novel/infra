variable "cluster_databases" {
  description = "Services whose database runs on the cluster. Each gets a Barman bucket, which its database's Kubernetes service account writes through Workload Identity."
  type = object({
    workload_project_id = string
    services            = set(string)
  })

  validation {
    condition     = alltrue([for service in var.cluster_databases.services : contains(["json-keys", "authentication", "genai", "narrative-engine"], service)])
    error_message = "Select supported services."
  }
}

variable "retired_barman_lineages" {
  description = "Backup lineages no database archives to any more, the cluster root's former backup_server_name values. Their objects expire 15 days after they were written."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for lineage in var.retired_barman_lineages : can(regex("^[a-z][a-z0-9-]{0,62}$", lineage))])
    error_message = "Name each retired lineage as the cluster root named it."
  }
}

data "google_project" "workload" {
  project_id = var.cluster_databases.workload_project_id
}

locals {
  # CloudNativePG names each database's Kubernetes service account after its Cluster, which the
  # cluster root names `database` in the service's namespace.
  barman_writers = {
    for service in var.cluster_databases.services : service => "principal://iam.googleapis.com/projects/${data.google_project.workload.number}/locations/global/workloadIdentityPools/${var.cluster_databases.workload_project_id}.svc.id.goog/subject/ns/${service}/sa/database"
  }
}

# Barman owns expiry, and a week of retention and soft deletion bounds a mistaken or hostile delete.
# Barman expires only the lineage its database archives to, so a retired lineage, which may hold a
# copy of production data, expires by age.
resource "google_storage_bucket" "barman" {
  for_each = var.cluster_databases.services

  project                     = var.management_project_id
  name                        = "${local.bucket_name_prefix}-barman-${each.key}"
  location                    = var.storage_location
  storage_class               = "STANDARD"
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = { service = each.key, purpose = "barman" }

  versioning {
    enabled = true
  }
  retention_policy {
    retention_period = 604800
    is_locked        = false
  }
  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  dynamic "lifecycle_rule" {
    for_each = var.retired_barman_lineages

    content {
      condition {
        matches_prefix = ["${lifecycle_rule.value}/"]
        age            = 15
      }
      action {
        type = "Delete"
      }
    }
  }

  # Deleting a versioned object keeps it as a prior version, which goes a day later.
  dynamic "lifecycle_rule" {
    for_each = var.retired_barman_lineages

    content {
      condition {
        matches_prefix             = ["${lifecycle_rule.value}/"]
        with_state                 = "ARCHIVED"
        days_since_noncurrent_time = 1
      }
      action {
        type = "Delete"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["storage.googleapis.com"]]
}

resource "google_project_iam_custom_role" "barman_writer" {
  project     = var.management_project_id
  role_id     = "barmanWriter"
  title       = "Barman Cloud writer"
  description = "Write and expire one database's Barman backups and WAL."
  stage       = "GA"
  # Barman reads the bucket before each archive and backup, and counts a refusal as lost
  # connectivity. It uploads base backups in parts, through the XML multipart API.
  permissions = [
    "storage.buckets.get",
    "storage.multipartUploads.abort",
    "storage.multipartUploads.create",
    "storage.objects.create",
    "storage.objects.delete",
    "storage.objects.get",
    "storage.objects.list",
  ]

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

# A recovery drill's database reads its source's backups and WAL, and can change nothing.
resource "google_project_iam_custom_role" "barman_reader" {
  project     = var.management_project_id
  role_id     = "barmanReader"
  title       = "Barman Cloud reader"
  description = "Read one database's Barman backups and WAL, for a recovery drill."
  stage       = "GA"
  permissions = ["storage.buckets.get", "storage.objects.get", "storage.objects.list"]

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

resource "google_storage_bucket_iam_member" "barman_writer" {
  for_each = local.barman_writers

  bucket = google_storage_bucket.barman[each.key].name
  role   = google_project_iam_custom_role.barman_writer.name
  member = each.value
}

output "barman_buckets" {
  description = "Each cluster database's Barman bucket, which only its own Kubernetes service account writes."
  value       = { for service, bucket in google_storage_bucket.barman : service => bucket.name }

  depends_on = [google_storage_bucket_iam_member.barman_writer]
}

output "barman_reader_role" {
  description = "The role a recovery drill grants its database on the Barman bucket it restores from."
  value       = google_project_iam_custom_role.barman_reader.name
}
