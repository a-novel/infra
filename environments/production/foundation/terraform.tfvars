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
region                 = "europe-west1"
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
# No VM runs in this region since the database hosts retired (a-novel/infra#1208): the ceiling only
# bounds a stray one's cost.
compute_cpu_quota = 24
# The whole project at moderate traffic, planned near EUR 360 a month, with margin.
monthly_budget_units = 500
