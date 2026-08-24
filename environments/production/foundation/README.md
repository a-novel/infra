# Production foundation root

This root owns durable workload infrastructure that survives ordinary application releases. It will
manage the workload project, IAM, private network, database host and storage, backups, monitoring, and
stable service definitions.

## State and authority

The protected foundation identity uses this root's isolated state and requires human approval for
changes. It may change durable production infrastructure. It has no standing secret-payload grant
and does not select routine application versions.

This root consumes only the bootstrap outputs needed to find the management plane and its own
automation identity; it does not copy bootstrap credentials or state into foundation state. The
same protected foundation identity is intentionally the post-bootstrap maintainer of both roots,
however, so an approved foundation workflow can update management-plane IAM and storage as well as
the workload foundation. Treat it as a high-trust control-plane identity. It has no standing secret
payload grant, and every use remains environment-approved and audited.

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
