access_policy_id = "36445243419"
authentication_maintenance_principals = [
  "user:geoffroy.vincent@agorastoryverse.com",
]
billing_account_id = "01BDFE-5B21E7-8393CB"
cost_alert_email   = "geoffroy.vincent@agorastoryverse.com"
database_capacity = {
  json-keys = {
    machine_type        = "e2-medium"
    container_cpu       = 0.75
    container_memory_mb = 1536
    max_connections     = 50
    data_disk_size_gb   = 50
  }
  authentication = {
    machine_type        = "e2-medium"
    container_cpu       = 0.75
    container_memory_mb = 1536
    max_connections     = 50
    data_disk_size_gb   = 50
  }
  # 20 concurrent 24 MiB writes peak at 2 GiB of PostgreSQL memory, and vacuum, TOAST compression
  # and pgBackRest need more than the one vCPU an e2-medium sustains.
  genai = {
    machine_type        = "e2-standard-2"
    container_cpu       = 1.5
    container_memory_mb = 6144
    max_connections     = 150
    data_disk_size_gb   = 50
  }
}
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
  "genai",
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
  genai = [
    "private",
  ]
}
subnet_cidr            = "10.20.0.0/24"
egress_subnet_cidr     = "10.20.1.0/24"
workload_project_id    = "a-novel-production-prod"
workload_project_name  = "A-Novel production"
host_credentials_image = "ghcr.io/a-novel/infra/host-credentials:sha-174f08b578fb131fa7a4112d1207829a5822797b-40242655253-1@sha256:9d3b315ef9104a651836926bc39953ef2659aece423f08025799f25cf74995ed"
native_backups = {
  json-keys = {
    ca_version        = "1"
    identity_version  = "2"
    wal_archiving     = true
    client_name       = "agora-database.a-novel-production-prod"
    schedules_enabled = true
  }
  authentication = {
    client_name       = "agora-authentication-database.a-novel-production-prod"
    ca_version        = "1"
    identity_version  = "1"
    wal_archiving     = true
    schedules_enabled = true
  }
}
database_releases = {
  json-keys = {
    revision             = "13df9600c58d376562c1809782d0c533a10e91c5"
    app_password_version = "1"
  }
  authentication = {
    revision             = "906476efeaeddef29b81dd7a32b9a6fa4e2ae0f6"
    app_password_version = "1"
  }
  genai = {
    revision             = "de87d803ccf9c4fff9d80bfe68862133d5e4ac2e"
    app_password_version = "1"
  }
}
# A blank line separates each service's pin, so concurrent release pull requests merge cleanly. Git
# refuses to merge edits to adjacent lines.
database_images = {
  json-keys = "ghcr.io/a-novel/service-json-keys/database:v2.13.2@sha256:8778711f5c9beb691b741b2edbbcccf4e5f857b0ff3380fbf2210dea194aab5a"

  authentication = "ghcr.io/a-novel/service-authentication/database:v2.17.0@sha256:6e8aab13a3f8a3cff10c39f87d8d50a3153dabe88d7da3b20786079239f68ae1"

  genai = "ghcr.io/a-novel/service-genai/database:v0.7.0@sha256:b31cb76b7909f052e7bc2d417a32c9c1b15b54bb394059d07bc8709ad7dd48da"
}
# json-keys and genai at their maximum instances, plus one rollout instance each, and the jobs.
cloud_run_cpu_quota_millicpu = 16000
cloud_run_memory_quota_bytes = 25769803776
# Three database hosts at their nominal vCPUs, plus the backup repository VMs.
compute_cpu_quota    = 8
monthly_budget_units = 150
