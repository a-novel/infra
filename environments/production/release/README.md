# Production release root

This root owns routine, manifest-driven application deployment. It will select database container
configuration, run jobs, create service revisions, shift traffic, and record the release state used
for application rollback.

## State and authority

The protected release identity uses this root's isolated state. Routine database deployment is the
one imperative edge: a fixed helper may update the foundation-owned group's five release values and
restart its existing member. The identity otherwise updates only application deployment resources;
it cannot change project IAM, VPC policy, remote-state protection, preserved database disks, backup
retention, or secret payloads.

Release deployment follows the fixed dependency order and restores the prior receipt if a health gate
fails. Backward-compatible migrations remain applied; restoring database contents is a separate
recovery operation.

## Current status

The root configures the Google provider from `workload_project_id` and `region`, declares its future
GCS backend, and validates both inputs with mocked tests. It currently contains no Google Cloud
resource blocks or deployment workflow. Both application components remain disabled in the release
manifest.

The future protected workflow will call the tested
[`deploy-database-release.sh`](../../../ops/deploy-database-release.sh) helper before jobs and
services. That helper updates five non-secret fields on the existing foundation-owned MIG and applies
them with a restart-only ceiling. Before mutation it requires the existing map to contain exactly
those five keys, preventing Google's merge behavior from retaining an unreviewed field. It is kept
outside OpenTofu because the provider's per-instance resource creates a new MIG member on first
apply; importing or duplicating the foundation-owned MIG would overlap state ownership. The helper
has no authenticated caller today.

## Resource inventory

The inventory is empty because this root manages no Google Cloud resources yet. A resource change
adds its OpenTofu address, Agora purpose, access and data boundary, lifecycle and recovery behavior,
cost impact, and links to both provider and Google Cloud product documentation.

Read the [architecture](../../../docs/architecture.md),
[Google Cloud provider guide](../../../docs/google-cloud.md), and
[database-host runbook](../../../docs/runbooks/operate-postgresql-host.md) before changing this root.
