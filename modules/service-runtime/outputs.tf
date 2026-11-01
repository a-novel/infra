output "repositories" {
  description = "Image repository URLs by purpose: production."
  value = { for purpose, repository in google_artifact_registry_repository.images :
    purpose => "${repository.location}-docker.pkg.dev/${repository.project}/${repository.repository_id}"
  }
}
