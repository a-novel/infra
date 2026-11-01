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

# Adopted for deletion with the old network (host-orphans.tf).
orphan_addresses = {
  "agora-database-authenticat-df08ea25-9fe5-3149-90f1-fb4e0ee5de46" = "10.20.0.4"
  "agora-database-genai-8d04-5b3025b3-d8e2-39eb-9aae-8fd3a5e57dd9"  = "10.20.0.8"
  "agora-database-json-keys-7-b30ad3ff-ba6c-3492-954d-9cefd89c86e1" = "10.20.0.5"
  "agora-database-k6qw-75644247-326b-31ea-9a22-75b9ff41ba02"        = "10.20.0.3"
  "agora-database-nc7n-e5e2f0ec-7d67-3efe-9a06-45e5c85cd9b5"        = "10.20.0.2"
}

orphan_snapshots = {
  "agora-data-authentication-20261013-155728" = "authentication"
  "agora-data-authentication-20261018-075206" = "authentication"
  "agora-data-authentication-20261018-140535" = "authentication"
  "agora-data-authentication-20261018-150254" = "authentication"
  "agora-data-authentication-20261018-165505" = "authentication"
  "agora-data-authentication-20261021-222000" = "authentication"
  "agora-data-authentication-20261022-005327" = "authentication"
  "agora-data-authentication-20261022-215650" = "authentication"
  "agora-data-authentication-20261025-180747" = "authentication"
  "agora-data-authentication-20261025-231255" = "authentication"
  "agora-data-authentication-20261026-203713" = "authentication"
  "agora-data-genai-20261018-140537"          = "genai"
  "agora-data-genai-20261018-150252"          = "genai"
  "agora-data-genai-20261018-154611"          = "genai"
  "agora-data-genai-20261018-165515"          = "genai"
  "agora-data-genai-20261021-222014"          = "genai"
  "agora-data-genai-20261022-224359"          = "genai"
  "agora-data-genai-20261025-193804"          = "genai"
  "agora-data-genai-20261025-222701"          = "genai"
  "agora-data-genai-20261026-210928"          = "genai"
  "agora-data-json-keys-20261013-154236"      = "json-keys"
  "agora-data-json-keys-20261018-075203"      = "json-keys"
  "agora-data-json-keys-20261018-140526"      = "json-keys"
  "agora-data-json-keys-20261018-150257"      = "json-keys"
  "agora-data-json-keys-20261018-165511"      = "json-keys"
  "agora-data-json-keys-20261021-134029"      = "json-keys"
  "agora-data-json-keys-20261021-222006"      = "json-keys"
  "agora-data-json-keys-20261022-214824"      = "json-keys"
  "agora-data-json-keys-20261024-152935"      = "json-keys"
  "agora-data-json-keys-20261025-231253"      = "json-keys"
  "agora-data-json-keys-20261026-210919"      = "json-keys"
}
