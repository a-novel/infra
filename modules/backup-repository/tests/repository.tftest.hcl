mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email  = "agora-pgbr-json-keys@agora-test.iam.gserviceaccount.com"
      member = "serviceAccount:agora-pgbr-json-keys@agora-test.iam.gserviceaccount.com"
      name   = "projects/agora-test/serviceAccounts/agora-pgbr-json-keys@agora-test.iam.gserviceaccount.com"
    }
  }
  mock_data "google_compute_instance_group" {
    defaults = { instances = ["projects/agora-test/zones/europe-west1-d/instances/agora-database-json-keys-test"] }
  }
}

variables {
  service    = "json-keys"
  project_id = "agora-test"
  region     = "europe-west1"
  placement = {
    zone       = "europe-west1-d"
    subnetwork = "projects/agora-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
    cos_image  = "projects/cos-cloud/global/images/cos-129-19506-505-8"
  }
  runtime = {
    server_image      = "europe-west1-docker.pkg.dev/agora-test/agora-json-keys-private-production/service-json-keys/database@sha256:d81116e5928bb9630185daf89d8918a56fb0ad6260eb87abfb7702c704a15374"
    credentials_image = "europe-west1-docker.pkg.dev/agora-test/agora-json-keys-private-tooling/host-credentials@sha256:a5e264fc51c824c52fb6fd59b035e14e52fdc9f77e47b0375b352d8ad9bfd00d"
    client_name       = "agora-database.agora-test"
    ca_version        = "1"
    identity_version  = "2"
  }
  bucket                    = "agora-management-test-1-pgbr-json-keys"
  management_project_number = "1"
  database = {
    group           = "agora-database-json-keys"
    zone            = "europe-west1-d"
    service_account = "agora-json-keys-database@agora-test.iam.gserviceaccount.com"
  }
  repository_ids       = { production = "agora-json-keys-private-production", tooling = "agora-json-keys-private-tooling" }
  deployer             = "infra-foundation@agora-management-test.iam.gserviceaccount.com"
  notification_channel = "projects/agora-test/notificationChannels/1"
}

run "keeps_the_repository_private_and_hardened" {
  command = plan

  assert {
    condition = (
      length(google_compute_instance.repository.network_interface[0].access_config) == 0 &&
      google_compute_instance.repository.deletion_protection &&
      google_compute_instance.repository.shielded_instance_config[0].enable_secure_boot &&
      google_compute_instance.repository.metadata["enable-oslogin"] == "TRUE" &&
      google_compute_instance.repository.metadata["block-project-ssh-keys"] == "TRUE"
    )
    error_message = "The repository VM must have no external IP, keep deletion protection and accept only OS Login."
  }

  assert {
    condition = (
      strcontains(google_compute_instance.repository.metadata["user-data"], "repo1-gcs-bucket=agora-management-test-1-pgbr-json-keys") &&
      strcontains(google_compute_instance.repository.metadata["user-data"], "tls-server-auth=agora-database.agora-test=json-keys") &&
      !strcontains(google_compute_instance.repository.metadata["user-data"], "expire-auto=y")
    )
    error_message = "The repository serves only its own bucket and database client, and never expires backups on its own."
  }
}
