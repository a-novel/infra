# Grants that served the retired release and custody tooling. They are adopted
# here only so that a-novel/infra#652 can delete them through the pipeline.

resource "google_artifact_registry_repository_iam_member" "retired_recovery_readers" {
  for_each = module.runtime.repository_ids

  location   = local.region
  repository = each.value
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:infra-recovery@${local.management_project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "retired_repository_ssh" {
  project = local.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:${local.deployer}"

  condition {
    title      = "RepositoryMaintenanceSSH-json-keys"
    expression = "destination.port == 22 && destination.ip == '10.20.0.6'"
  }
}
