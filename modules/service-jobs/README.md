# Service application jobs

This module owns one service's Cloud Run job specifications. JSON Keys has migrations and rotation;
Authentication has migrations. The shared resource pattern takes the
[service foundation's](../service-foundation) versioned `runtime` output, one approved private
database address, Shared VPC coordinates, promoted job digests and numeric secret versions.

**Code only:** no production root calls this module. Applying a job specification does not run it.
The module creates no API, initializer, scheduler, identity or IAM grant. Cloud Deploy owns API
specifications and traffic; database hosts remain foundation-owned. Existing production addresses
and state stay unchanged until a separately approved one-writer handoff.

## Inputs and execution boundary

`images` contains `migrations` and, for JSON Keys, `rotatekeys`. Each image must use its exact
service/job path in the selected project's regional `agora-production` repository. Before apply,
the caller verifies the complete service image family and producer provenance; these HCL path/digest
checks do not establish either. `secret_versions` contains `postgres-password` and, for JSON Keys,
`app-master-key`, with positive integer versions whose enabled state the caller verifies separately.

Migrations mount only their PostgreSQL password reference. Rotation additionally mounts the master
key. The shared application identity retains its service-foundation grants, including Authentication's
SMTP permission; mounted references do not restrict that identity's effective IAM. Payloads never
enter OpenTofu inputs or outputs. The caller must authorize all coordinates against the selected
service's foundation; syntactic validation alone cannot prove ownership of an address or subnet.

Each execution has one task on 1 CPU / 512 MiB with the image's own entrypoint. Migrations have a
ten-minute timeout and zero task retries; idempotent rotation has five minutes and one retry.
Google's [task retry setting](https://docs.cloud.google.com/run/docs/configuring/max-retries)
does not prevent two separately dispatched executions. Keep same-service exclusion around job
updates, migrations, scheduling, API rollout and receipt publication. An ambiguous migration dispatch
requires reconciliation of its exact execution; neither a timeout nor a missing receipt permits replay.

Both job types use all-traffic Direct VPC egress and their service's network tag. The host foundation
must provide private database access, restricted Google API routing and the Cloud Run service-agent
subnet grant. PostgreSQL keeps the existing private non-TLS transport contract. Verify effective
network and IAM denial, including peer database access, before activation.

The protected foundation supplies job-writer/identity-attachment permissions and separately reviewed
exact-job invocation grants. Job writers must not gain IAM administration from this module.
Migration execution remains outside Cloud Deploy retry hooks. Rotation scheduling needs a separate
invocation identity, paused activation and a reviewed pause/drain/resume procedure before deployment.
Neither project-wide invoker grants nor the legacy fleet invocation tags are copied here.

The `jobs` output records the declared names, resource UIDs and images. It is configuration, not
execution or health evidence. A dispatcher must inspect the live definition and retain the native
operation/execution identity. Recovery into another project uses its own approved restored-data path;
it must not accidentally recreate production mutation jobs.

Deletion protection and OpenTofu lifecycle guards require an explicit reviewed retirement. Native
plan-only tests use mocked providers for both service contracts and safety-sensitive invalid inputs.
They provide no live IAM, database readiness or migration-recovery proof. The
[pinned provider resource](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/cloud_run_v2_job.html.markdown)
owns configuration convergence; no additional setup script or dependency is needed.
