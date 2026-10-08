authentication_initializer_principals = [
  "user:geoffroy.vincent@agorastoryverse.com",
]
backup_bucket_name = "a-novel-management-prod-232403541574-backups"
billing_account_id = "01BDFE-5B21E7-8393CB"
cost_alert_email   = "geoffroy.vincent@agorastoryverse.com"
database_operator_principals = [
  "user:geoffroy.vincent@agorastoryverse.com",
]
database_zone          = "europe-west1-d"
folder_id              = null
management_project_id  = "a-novel-management-prod"
operations_alert_email = "geoffroy.vincent@agorastoryverse.com"
organization_id        = "1031663934757"
pgbackrest_repository_services = [
  "json-keys",
  "authentication",
]
public_api_project_id = "a-novel-public-api-prod"
public_project_id     = "a-novel-public-prod"
region                = "europe-west1"
service_release_zones = {
  authentication = [
    "private",
    "public-api",
  ]
  json-keys = [
    "private",
  ]
}
shared_vpc_enabled    = true
subnet_cidr           = "10.20.0.0/24"
workload_project_id   = "a-novel-production-prod"
workload_project_name = "Agora production"
native_backups = {
  json-keys = {
    repository_ip     = "10.20.0.6"
    credentials_image = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-json-keys-private-tooling/host-credentials@sha256:a5e264fc51c824c52fb6fd59b035e14e52fdc9f77e47b0375b352d8ad9bfd00d"
    ca_version        = "1"
    identity_version  = "2"
    wal_archiving     = true
    client_name       = "agora-database.a-novel-production-prod"
    schedules_enabled = true
  }
  authentication = {
    repository_ip     = "10.20.0.7"
    credentials_image = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-authentication-private-tooling/host-credentials@sha256:a5e264fc51c824c52fb6fd59b035e14e52fdc9f77e47b0375b352d8ad9bfd00d"
    client_name       = "agora-authentication-database.a-novel-production-prod"
    ca_version        = "1"
    identity_version  = "1"
    wal_archiving     = true
    schedules_enabled = true
  }
}
database_releases = {
  json-keys = {
    revision         = "13df9600c58d376562c1809782d0c533a10e91c5"
    password_version = "2"
  }
  authentication = {
    revision         = "906476efeaeddef29b81dd7a32b9a6fa4e2ae0f6"
    password_version = "2"
  }
}
database_images = {
  json-keys      = "ghcr.io/a-novel/service-json-keys/database:v2.6.6@sha256:d81116e5928bb9630185daf89d8918a56fb0ad6260eb87abfb7702c704a15374"
  authentication = "ghcr.io/a-novel/service-authentication/database:v2.11.0@sha256:78bcd4cba6aa60c37e46fad0b8625c8424d118014fc5efa645e0bdee05a8d871"
}
