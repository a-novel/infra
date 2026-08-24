# Bootstrap root

This root owns the stable recovery plane that lets later automation manage and rebuild production.
It changes rarely and carries the narrow authority needed to establish remote state, federation,
automation identities, recovery storage, and secret metadata.

## State and authority

The first application starts with operator-controlled local state because a GCS backend bucket must
exist before OpenTofu can use it. The bootstrap runbook will create and verify that bucket, migrate
the state, and remove temporary broad access. Later runs use the remote backend and the protected
bootstrap identity.

This root may create identities used by later roots. It does not deploy workload networking,
databases, or application revisions.

## Current status

The root configures the Google provider from `management_project_id` and `region`, declares the future
GCS backend, and validates both inputs with mocked tests. It currently contains no Google Cloud
resource blocks.

## Resource inventory

The inventory is empty because this root manages no Google Cloud resources yet. A resource change
adds its OpenTofu address, Agora purpose, access and data boundary, lifecycle and recovery behavior,
cost impact, and links to both provider and Google Cloud product documentation.

Read the [architecture](../docs/architecture.md) and
[Google Cloud provider guide](../docs/google-cloud.md) before changing this root.
