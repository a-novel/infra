access_policy_id = "36445243419"
authentication_maintenance_principals = [
  "user:geoffroy.vincent@agorastoryverse.com",
]
billing_account_id = "01BDFE-5B21E7-8393CB"
cost_alert_email   = "geoffroy.vincent@agorastoryverse.com"
database_operator_principals = [
  "user:geoffroy.vincent@agorastoryverse.com",
]
folder_id              = null
management_project_id  = "a-novel-management-prod"
operations_alert_email = "geoffroy.vincent@agorastoryverse.com"
organization_id        = "1031663934757"
public_api_project_id  = "a-novel-public-api-prod"
public_project_id      = "a-novel-public-prod"
region                 = "europe-west1"
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
# A ceiling only Google raises, above the node pool's maximum: deliberate growth past it starts with
# a quota request.
cluster_compute_cpu_quota = 24
# The nodes' boot disks and the databases' volumes peak near 240 GB. Above Google's default of 500,
# this leaves room for narrative-engine's projects; the request applies once Google grants it.
cluster_ssd_quota_gb = 1000
# The control plane runs in the first zone. Three nodes hold every service and each database's
# primary and replica: each instance's volume keeps it in its zone. Memory bounds them, not CPU, so
# the nodes are highmem: two of them still hold every pod's requests if the third is lost
# (a-novel/infra#1326). The autoscaler adds a node only when pods cannot be placed, and only to
# absorb a spike or transient load: one more at most. Capacity that stays is a decision, which
# Grafana prompts once the cluster runs above its baseline for two hours or at its maximum.
cluster = {
  zones        = ["europe-west9-a", "europe-west9-b"]
  machine_type = "e2-highmem-4"
  min_nodes    = 3
  max_nodes    = 4
}
# Apart from agora-production's ranges, which the import peering joins. The pods' /20 holds 16 nodes
# at 110 pods each.
cluster_ranges = {
  nodes    = "10.30.0.0/24"
  services = "10.30.4.0/22"
  pods     = "10.30.16.0/20"
}
workload_project_id   = "a-novel-production-prod"
workload_project_name = "A-Novel production"
# A blank line separates each service's pin, so concurrent release pull requests merge cleanly. Git
# refuses to merge edits to adjacent lines.
database_images = {
  json-keys = "ghcr.io/a-novel/service-json-keys/database:v2.14.1@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a"

  authentication = "ghcr.io/a-novel/service-authentication/database:v2.20.1@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"

  genai = "ghcr.io/a-novel/service-genai/database:v0.8.1@sha256:880e760f2f03f4ffdaf2affc186d10a91a12f711602a4c0983a9d70d837efb70"
}
# No VM runs in this region since the database hosts retired (a-novel/infra#1208): the ceiling only
# bounds a stray one's cost.
compute_cpu_quota = 24
# The whole project at moderate traffic, planned near EUR 360 a month, with margin.
monthly_budget_units = 500
