# Single-service release root (inactive)

This root owns one service's Cloud Run job specifications. JSON Keys has migrations and rotation;
Authentication has migrations. The shared resource pattern takes the
[service foundation's](../service-foundation) versioned `runtime` output, one approved private
database address, Shared VPC coordinates, promoted job digests and numeric secret versions.
Foundation publishes its runtime and optional database/rollout outputs in a
[content-addressed document](../service-foundation#published-coordinates). The future caller must use
an explicitly approved reference, verify its scope/generation/checksum, and require independent
database readiness evidence. The document's presence does not approve a release or a partially
completed foundation apply. This root does not read that document or foundation state itself.

**Code only:** no deployment workflow or live root allowlist selects this directory. Applying a job
specification does not run it. The root creates no API, initializer, scheduler, identity or IAM grant.
Cloud Deploy owns API specifications and traffic; protected foundation owns databases, IAM, schedules
and alerts. Existing production resources and state stay unchanged.

## State and resource ownership

The [workload project](../../modules/workload-project) publishes the service's release identity and
`release.state` coordinates. Set `state_bucket` to that published bucket; the native GCS backend
derives `services/PROJECT/release/` from `runtime.project_id`. Only the default workspace is accepted,
so its state object is `services/PROJECT/release/default.tfstate`. The provider uses that same project
and region. Inputs contain numeric secret versions and approved coordinates, never payloads.

The bucket check constrains its management-project naming convention, not its ownership. The future
protected caller must authorize inputs against the published coordinates before initialization, use a
fresh working directory, and prohibit backend overrides. Keep credentials in the approved federation
environment. [GCS locking](https://opentofu.org/docs/language/settings/backends/gcs/) covers OpenTofu
operations; migrations and Cloud Deploy still require the broader same-service exclusion.

| Root resource address                               | Owner and lifecycle                                                                   |
| --------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `google_cloud_run_v2_job.application["migrations"]` | Selected service's migration specification; never dispatched by apply.                |
| `google_cloud_run_v2_job.application["rotatekeys"]` | JSON Keys only; rotation specification, independent of its foundation-owned schedule. |

Both jobs have provider deletion protection and `prevent_destroy`. Updating a specification affects
subsequent executions, not already-running tasks. The inactive root allocates nothing today; once
activated, job execution and logging incur costs. Its version-1 `jobs` output contains names, UIDs and
images, not execution or health evidence. Dispatchers must inspect live definitions and retain native
operation/execution identities.

## Bootstrap before routine release

A separately reviewed protected bootstrap must create the jobs **in this destination state** after
the project, runtime, registry, network and database prerequisites exist. Then protected foundation
installs [exact-job access](../../modules/service-job-access), the paused rotation schedule and alerts.
Verify effective allowed/denied operations, remove temporary bootstrap authority, and prove a
zero-change plan with the routine release identity before enabling its caller.

Routine release can update existing jobs, not create replacements. A missing job or interrupted
bootstrap stops for reconciliation of state, native job UIDs and accepted operations. Preserve a
private state backup and exact reviewed plan at each ownership transition. If a pilot job is already
managed elsewhere, review its state removal/import addresses before using this root; do not adopt it
automatically. Import cannot relocate a job from the legacy workload project into a service project.
Keep the legacy writer and retained receipts/backups until the separate workload cutover is proven.

Activation still requires complete-family/provenance and enabled secret metadata checks, private
saved-plan custody, deletion authorization bound to the root/service/commit, same-service exclusion
and an isolated interruption drill. No live apply or state-transfer command is enabled here.

## Inputs and execution boundary

`images` contains `migrations` and, for JSON Keys, `rotatekeys`. Each image must use its exact
service/job path in the selected project's regional `agora-production` repository. `secret_versions`
contains `postgres-password` and, for JSON Keys, `app-master-key`, with positive integer versions.
These HCL syntax checks do not establish producer provenance, enabled versions or ownership of an
address/subnet; the caller must verify those against the selected service's protected inputs.

Migrations mount only their PostgreSQL password reference. Rotation additionally mounts the master
key. The shared application identity retains its service-foundation grants, including Authentication's
SMTP permission; mounted references do not restrict that identity's effective IAM. Payloads never
enter OpenTofu inputs or outputs.

Each execution has one task on 1 CPU / 512 MiB with the image's own entrypoint. Migrations have a
ten-minute timeout and zero task retries; idempotent rotation has five minutes and one retry.
Google's [task retry setting](https://docs.cloud.google.com/run/docs/configuring/max-retries)
does not prevent two separately dispatched executions. Keep same-service exclusion around job
updates, migrations, API rollout and receipt publication, including pausing/draining/resuming rotation.
Migrations remain outside Cloud Deploy retry hooks. An ambiguous dispatch requires reconciliation of
its exact execution; neither a timeout nor a missing receipt permits replay.

Both job types use all-traffic Direct VPC egress and their service's network tag. The host foundation
must provide private database access, restricted Google API routing and the Cloud Run service-agent
subnet grant. PostgreSQL keeps the existing private non-TLS transport contract. Verify effective
network and IAM denial, including peer database access, before activation.

Neither project-wide invoker grants nor legacy fleet invocation tags are copied here. Recovery into
another project uses its own approved restored-data path, not these production mutation jobs.

## Cloud-blind validation

The existing CI validation job runs this root directly with the committed provider lock and no
backend initialization. Its plan-only tests mock the only provider, including both service contracts
and safety-sensitive invalid inputs:

```sh
tofu -chdir=environments/service-release init -backend=false -input=false -lockfile=readonly
tofu -chdir=environments/service-release validate
tofu -chdir=environments/service-release test
```

They provide no live IAM, database readiness or migration-recovery proof. The
[pinned provider resource](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/cloud_run_v2_job.html.markdown)
owns configuration convergence. OpenTofu's [backend variables](https://opentofu.org/docs/language/settings/backends/configuration/#variables-and-locals)
bind the state prefix directly to the selected project without a backend-file generator.
