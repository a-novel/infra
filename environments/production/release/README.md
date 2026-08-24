# Production release root

This root owns routine, manifest-driven application deployment. It will select database container
templates, run jobs, create service revisions, shift traffic, and record the release state used for
application rollback.

## State and authority

The protected release identity uses this root's isolated state and can update only application
deployment resources. It cannot change project IAM, VPC policy, remote-state protection, preserved
database disks, backup retention, or secret payloads.

Release deployment follows the fixed dependency order and restores the prior receipt if a health gate
fails. Backward-compatible migrations remain applied; restoring database contents is a separate
recovery operation.

## Current status

The root configures the Google provider from `workload_project_id` and `region`, declares its future
GCS backend, and validates both inputs with mocked tests. It currently contains no Google Cloud
resource blocks or deployment workflow. Both application components remain disabled in the release
manifest.

## Resource inventory

The inventory is empty because this root manages no Google Cloud resources yet. A resource change
adds its OpenTofu address, Agora purpose, access and data boundary, lifecycle and recovery behavior,
cost impact, and links to both provider and Google Cloud product documentation.

Read the [architecture](../../../docs/architecture.md) and
[Google Cloud provider guide](../../../docs/google-cloud.md) before changing this root.
