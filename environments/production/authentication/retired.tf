# Grants that served the retired release and custody tooling. They are adopted
# here only so that a-novel/infra#652 can delete them through the pipeline.

resource "google_artifact_registry_repository_iam_member" "retired_private_recovery_readers" {
  for_each = module.private_runtime.repository_ids

  project    = local.private_project_id
  location   = local.region
  repository = each.value
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:infra-recovery@${local.management_project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "retired_private_repository_ssh" {
  project = local.private_project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:${local.deployer}"

  condition {
    title      = "RepositoryMaintenanceSSH-authentication"
    expression = "destination.port == 22 && destination.ip == '10.20.0.7'"
  }
}

resource "google_artifact_registry_repository_iam_member" "retired_api_recovery_readers" {
  for_each = module.api_runtime.repository_ids

  project    = local.api_project_id
  location   = local.region
  repository = each.value
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:infra-recovery@${local.management_project_id}.iam.gserviceaccount.com"
}

resource "google_secret_manager_secret_iam_member" "retired_secret_viewers" {
  for_each = toset(["production-authentication-postgres-password", "production-authentication-smtp-sender-password"])

  project   = local.management_project_id
  secret_id = each.value
  role      = "roles/secretmanager.viewer"
  member    = "serviceAccount:${local.deployer}"
}
