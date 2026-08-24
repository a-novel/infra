# Production foundation root

This root owns durable workload infrastructure that survives ordinary application releases. It will
manage the workload project, IAM, private network, database host and storage, backups, monitoring, and
stable service definitions.

## State and authority

The protected foundation identity uses this root's isolated state and requires human approval for
changes. It may change durable production infrastructure. It cannot read secret payloads or select
routine application versions.

The foundation consumes only the bootstrap outputs needed to find the management plane and its own
automation identity. It does not inherit bootstrap authority.

## Current status

The root configures the Google provider from `workload_project_id` and `region`, declares its future
GCS backend, and validates both inputs with mocked tests. It currently contains no Google Cloud
resource blocks, so the planned private network and database isolation are not enforced yet.

## Resource inventory

The inventory is empty because this root manages no Google Cloud resources yet. A resource change
adds its OpenTofu address, Agora purpose, access and data boundary, lifecycle and recovery behavior,
cost impact, and links to both provider and Google Cloud product documentation.

Read the [architecture](../../../docs/architecture.md) and
[Google Cloud provider guide](../../../docs/google-cloud.md) before changing this root.
