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
subnet_cidr        = "10.20.0.0/24"
egress_subnet_cidr = "10.20.1.0/24"
# The cluster runs in Paris. Cloud Run, the database hosts and the old network keep region until they
# retire.
cluster_region = "europe-west9"
# Three e2-standard-4 nodes and one surge node.
cluster_compute_cpu_quota = 16
# The nodes' boot disks and the databases' volumes peak near 240 GB. Above Google's default of 500,
# this leaves room for narrative-engine's projects; the request applies once Google grants it.
cluster_ssd_quota_gb = 1000
# The control plane runs in the first zone. Two nodes hold every service and each database's
# primary and replica, and the autoscaler adds a third; narrative-engine revisits the shape.
cluster = {
  zones        = ["europe-west9-a", "europe-west9-b"]
  machine_type = "e2-standard-4"
  min_nodes    = 2
  max_nodes    = 3
}
# Apart from agora-production's ranges, which the import peering joins. The pods' /20 holds 16 nodes
# at 110 pods each.
cluster_ranges = {
  nodes    = "10.30.0.0/24"
  services = "10.30.4.0/22"
  pods     = "10.30.16.0/20"
}
sentry_ingest_host     = "o4504952660951040.ingest.us.sentry.io"
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
  json-keys = "ghcr.io/a-novel/service-json-keys/database:v2.14.0@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a"

  authentication = "ghcr.io/a-novel/service-authentication/database:v2.19.1@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"

  genai = "ghcr.io/a-novel/service-genai/database:v0.8.1@sha256:880e760f2f03f4ffdaf2affc186d10a91a12f711602a4c0983a9d70d837efb70"
}
# json-keys and genai at their maximum instances, plus one rollout instance each, and the jobs.
cloud_run_cpu_quota_millicpu = 16000
cloud_run_memory_quota_bytes = 25769803776
# Three database hosts at their nominal vCPUs and the backup repository VMs (8), plus the cluster's
# three e2-standard-4 nodes and one surge node (16). Retirement lowers it once the hosts go.
compute_cpu_quota = 24
# The whole project at moderate traffic, planned near EUR 360 a month, with margin.
monthly_budget_units = 500
