variable "legacy_backup_job_access" {
  description = "Opt in only after the five legacy backup jobs exist; add their maintenance tag and foundation access without running them."
  type        = bool
  default     = false
}

locals {
  legacy_backup_job_access = var.legacy_backup_job_access && !var.recovery_mode
  legacy_backup_jobs = local.legacy_backup_job_access ? toset([
    "agora-postgres-backup-json-keys", "agora-postgres-restore-json-keys",
    "agora-postgres-backup-authentication", "agora-postgres-restore-authentication",
    "agora-postgres-backup-monitor",
  ]) : toset([])
}

# A separate key preserves the existing scheduled tag and its callers.
resource "google_tags_tag_key" "legacy_backup" {
  count       = local.legacy_backup_job_access ? 1 : 0
  parent      = "projects/${google_project.workload.number}"
  short_name  = "agora-backup-maintenance"
  description = "Foundation invocation of existing backup safety jobs."

  depends_on = [google_project_service.workload["cloudresourcemanager.googleapis.com"]]
}

resource "google_tags_tag_value" "legacy_backup" {
  count       = local.legacy_backup_job_access ? 1 : 0
  parent      = google_tags_tag_key.legacy_backup[0].id
  short_name  = "enabled"
  description = "Existing legacy backup, restore-check and backup-monitor jobs only."
}

resource "google_tags_tag_value_iam_member" "foundation_backup_tag" {
  count     = local.legacy_backup_job_access ? 1 : 0
  tag_value = google_tags_tag_value.legacy_backup[0].name
  role      = "roles/resourcemanager.tagUser"
  member    = "serviceAccount:${local.automation_service_accounts.foundation}"
}

resource "google_tags_location_tag_binding" "legacy_backup" {
  for_each = local.legacy_backup_jobs

  parent    = "//run.googleapis.com/projects/${google_project.workload.project_id}/locations/${var.region}/jobs/${each.value}"
  location  = var.region
  tag_value = google_tags_tag_value.legacy_backup[0].id

  depends_on = [google_tags_tag_value_iam_member.foundation_backup_tag, google_project_iam_member.foundation_backup_tagging]
}

resource "google_project_iam_custom_role" "foundation_backup_tagging" {
  count       = local.legacy_backup_job_access ? 1 : 0
  project     = google_project.workload.project_id
  role_id     = "infraFoundationBackupTagging"
  title       = "Infra Foundation Backup Tagging"
  description = "Maintain the additional backup tag on existing scheduled jobs through reviewed foundation plans."
  permissions = ["run.jobs.createTagBinding", "run.jobs.deleteTagBinding", "run.jobs.listTagBindings"]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "foundation_backup_tagging" {
  count   = local.legacy_backup_job_access ? 1 : 0
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_backup_tagging[0].name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"

  condition {
    title       = "FoundationScheduledJobTaggingOnly"
    description = "Tag administration only; reviewed plans restrict attachment to the five backup safety jobs."
    expression  = "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation["scheduled"].id}')"
  }
}

resource "google_project_iam_custom_role" "foundation_backup_jobs" {
  count   = local.legacy_backup_job_access ? 1 : 0
  project = google_project.workload.project_id

  role_id     = "infraFoundationBackupJobs"
  title       = "Infra Foundation Backup Jobs"
  description = "Run existing scheduled backup, restore-check and backup-monitor jobs without overrides or cancellation."
  permissions = ["run.jobs.run"]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "foundation_backup_jobs" {
  count   = local.legacy_backup_job_access ? 1 : 0
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_backup_jobs[0].name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"

  condition {
    title       = "FoundationBackupJobsOnly"
    description = "The dedicated backup tag excludes key rotation, migration, initializer and application workloads."
    expression  = "resource.matchTagId('${google_tags_tag_key.legacy_backup[0].id}', '${google_tags_tag_value.legacy_backup[0].id}')"
  }
}

# Execution polling is read-only. Cloud Run operations do not carry the job tag,
# so observation is project-scoped; invocation remains conditional above.
resource "google_project_iam_custom_role" "foundation_backup_observation" {
  count   = local.legacy_backup_job_access ? 1 : 0
  project = google_project.workload.project_id

  role_id     = "infraFoundationBackupObservation"
  title       = "Infra Foundation Backup Observation"
  description = "Read job and execution metadata while waiting for maintenance recovery checks."
  permissions = ["run.jobs.get", "run.executions.get", "run.operations.get"]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "foundation_backup_observation" {
  count   = local.legacy_backup_job_access ? 1 : 0
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_backup_observation[0].name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"
}
