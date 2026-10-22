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
shared_vpc_enabled     = true
subnet_cidr            = "10.20.0.0/24"
egress_subnet_cidr     = "10.20.1.0/25"
workload_project_id    = "a-novel-production-prod"
workload_project_name  = "A-Novel production"
host_credentials_image = "ghcr.io/a-novel/infra/host-credentials:sha-fd585ed07563425b0268432163f43f7b21590255-37551742865-1@sha256:a5e264fc51c824c52fb6fd59b035e14e52fdc9f77e47b0375b352d8ad9bfd00d"
native_backups = {
  json-keys = {
    repository_ip     = "10.20.0.6"
    ca_version        = "1"
    identity_version  = "2"
    wal_archiving     = true
    client_name       = "agora-database.a-novel-production-prod"
    schedules_enabled = true
  }
  authentication = {
    repository_ip     = "10.20.0.7"
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
database_images = {
  json-keys      = "ghcr.io/a-novel/service-json-keys/database:v2.12.1@sha256:f1072d3e67f7c333eb84c35b1be9bdad6bb3beae362a6d808b39f2f2ec073c11"
  authentication = "ghcr.io/a-novel/service-authentication/database:v2.15.1@sha256:c4d8cb051e88c721912037537e6546694736f8f0183cc59994c230369fbc593c"
  genai          = "ghcr.io/a-novel/service-genai/database:v0.6.0@sha256:f31800ea3c86e1d9d083ef736c4a301a2e7aeaa010e04bb152cba7963efb65c2"
}
# json-keys and genai at their maximum instances, plus one rollout instance each, and the jobs.
cloud_run_cpu_quota_millicpu = 16000
cloud_run_memory_quota_bytes = 25769803776
# Three database hosts at their nominal vCPUs, plus the backup repository VMs.
compute_cpu_quota    = 8
monthly_budget_units = 150
