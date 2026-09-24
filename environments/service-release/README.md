# Single-service release root (inactive)

This root owns one service's Cloud Run job specifications and can output its native API release request.
JSON Keys has migrations and rotation; Authentication has migrations.
The shared resource pattern derives the application identity and
database endpoint from the [foundation's published document](../service-foundation#published-coordinates).
OpenTofu validates its checksum and service scope against independently approved inputs. Shared VPC
coordinates, promoted image digests and numeric secret versions remain separate inputs. Neither this
root nor its future caller needs foundation-state access.

**Code only:** trusted assessment and drift can inspect this root. The protected
[job bootstrap](../../docs/runbooks/provision-service-projects.md#protected-service-job-bootstrap)
is disabled by default; routine release remains unconnected.
Applying a job specification does not run it. The root creates no API, initializer, scheduler, identity or IAM grant.
Cloud Deploy owns API specifications and traffic; protected foundation owns databases, IAM, schedules
and alerts. Existing production resources and state stay unchanged.

## State and resource ownership

The [workload project](../../modules/workload-project) publishes the service's release identity and
`release.state` coordinates. Set `state_bucket` to that published bucket; the native GCS backend
derives `services/PROJECT/release/` from `project_id`. Only the default workspace is accepted,
so its state object is `services/PROJECT/release/default.tfstate`. The provider uses that same project
and region. Inputs contain numeric secret versions and approved coordinates, never payloads.

The bucket check constrains its management-project naming convention, not its ownership. The future
protected caller must authorize inputs against the published coordinates before initialization, use a
fresh working directory, and prohibit backend overrides. Keep credentials in the approved federation
environment. [GCS locking](https://opentofu.org/docs/language/settings/backends/gcs/) covers OpenTofu
operations; migrations and Cloud Deploy still require the broader same-service exclusion.

## Read-only assessment and drift

The existing inspector selects projects from the last converged shared-foundation registration.
It inventories native managed-folder metadata under `services/`, then reads objects only within each
registered `services/PROJECT/release/` folder. The plan identity's existing folder-scoped access is
sufficient; no bucket-wide object grant is required. Missing or unregistered folders stop inspection.

A confirmed empty folder is skipped. Initialized state requires its matching converged inputs at
`services/PROJECT/release/config/RUN-ATTEMPT.tfvars.json`, using the existing zero-padded sequence format.
Missing inputs, inputs without state, unexpected workspaces/locks and denied reads stop inspection.
The trusted coordinate guard validates each backend against registration before initialization with
fresh local metadata. Writer enable flags do not exempt existing state from assessment or drift.

Service-root changes and shared-module changes use the existing exact-candidate approval and private
plan policy. Public verdicts contain no state, plan or configuration values. Read-only inspection
remains available regardless of the bootstrap enable flag.

## Private plan custody

The existing `infra custody plan` command supports this root inside its existing managed folder:
`services/PROJECT/release/plans/COMMIT/RUN-ATTEMPT/`. Each plan has `plan.tfplan` and
`plan.metadata.json`; there is no extra storage grant or second plan implementation. Inspection ignores
only these exact artifact names beneath valid commit/sequence paths. Plans alone do not establish state.

For `service-release`, `publish` and `fetch` require the private tfvars filename as their **last** argument,
after the existing arguments (`publish`: bucket, root, commit, plan ID, plan file, destructive marker;
`fetch`: bucket, root, commit, plan ID, destination). Both bind the exact input bytes by SHA-256.
Changing even formatting requires a new plan. Missing or different inputs stop before the opaque plan
is downloaded. Root/project/commit/sequence, checksum, deletion marker and the 24-hour expiry retain
their existing checks. Legacy plan paths and metadata remain compatible.

Publication is create-only. A lost upload acknowledgement or partial publication stops; inspect the
exact objects rather than overwriting or assuming no upload occurred. `consume` retains its existing
arguments and removes the selected pair before apply. A failed or ambiguous consumption
must block mutation. The provider owns state locking; custody is neither deployment authorization nor
a same-service execution lock. The protected workflow retains global infrastructure serialization,
authorizes the inputs, consumes the plan, applies it and verifies convergence before publishing inputs.

Metadata enforces the 24-hour apply deadline. Bootstrap declares native
[plan cleanup](../../bootstrap/README.md#plan-artifact-expiration) after age 2 days, restricted to the
`services/` prefix and the two artifact suffixes. Cleanup is asynchronous and keeps seven-day soft delete.
Protected bootstrap apply and live verification remain prerequisites before writer activation.
`SERVICE_JOB_BOOTSTRAP_ENABLED=true` permits only create/no-op plans for this service's exact
application jobs. Updates, imports, moves, replacements, deletions and other resources fail regardless
of deletion approval. Routine writes and output export remain disabled.

## Approved foundation handoff

The inactive root accepts three independently authorized selectors: `project_id`, `service` and
`region`. Its `foundation` input is the exact version-1 reference returned by foundation: `bucket`,
`object`, `generation` and `sha256`. `foundation_json` is that object's original JSON text, not a
reconstructed subset. The earlier standalone `runtime` and `database_private_ip` inputs are removed;
no live caller used this root.

Protected bootstrap uses the following handoff:

1. Authorize the selectors, backend and reference against protected registration before initialization.
   The operator approves the reference only after protected foundation apply and convergence succeed.
2. Fetch that exact object generation using the existing Google CLI or SDK. Native
   [generation-qualified object names](https://docs.cloud.google.com/storage/docs/using-versioned-objects)
   use `gs://BUCKET/OBJECT#GENERATION`; quote the full name. Do not list/select the newest object, omit
   the generation or fall back after a failed read.
3. Pass the original JSON text as `foundation_json`, without pretty-printing, trimming or re-encoding it.
   HCL verifies the approved checksum, reference namespace, document/runtime/database versions, exact
   service scope, runtime identity and private database endpoint. It requires a database contract;
   foundation snapshots taken before database provisioning are rejected. Configuring the optional API
   request also requires the document's exact JSON Keys pipeline and target.
4. Preserve the approved reference and inputs with the private saved plan, then use the existing
   convergence and serialized execution boundaries. A saved plan owns its captured
   values; changing the input document requires a new reviewed plan, not an apply-time substitution.

HCL verifies received content, not a cloud download it did not perform. A generation string alone
does not prove where those bytes came from; reference approval and exact retrieval remain caller
obligations. The [pinned provider's content data source](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/google/services/storage/data_source_storage_bucket_object_content.go)
does not support generation selection, so the root does not use it for this handoff. No custom
downloader or new dependency is introduced.

Coordinates describe configuration, not database health, firewall reachability or migration history.
Require separate readiness evidence, verify effective IAM, and retain every referenced object generation
through the lifetime of its consumers. A document left by an interrupted foundation apply is not approval.
Automatic reference approval and routine release remain unconnected.

| Root resource address                               | Owner and lifecycle                                                                   |
| --------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `google_cloud_run_v2_job.application["migrations"]` | Selected service's migration specification; never dispatched by apply.                |
| `google_cloud_run_v2_job.application["rotatekeys"]` | JSON Keys only; rotation specification, independent of its foundation-owned schedule. |

Both jobs have provider deletion protection and `prevent_destroy`. Updating a specification affects
subsequent executions, not already-running tasks. The inactive root allocates nothing today; once
activated, job execution and logging incur costs. Its version-1 `jobs` output contains names, UIDs and
images, not execution or health evidence. Dispatchers must inspect live definitions and retain native
operation/execution identities.

## Native API request

`rollout` defaults to `null`, leaving both service job contracts unchanged. Opting in requires
`project_number`, `image`, `release_id`, `request_id`, `source_commit` and `skaffold_version`.
Only JSON Keys is supported. The image must be its promoted gRPC digest; release/source/Skaffold pins
must satisfy the [native submitter contract](../../docs/runbooks/submit-release.md#the-private-request).
Choose and retain the release ID and UUID before planning, never with `uuid()`, `timestamp()` or a
retry-time replacement. Independently authorize the numeric service project and its ID relationship.

The approved foundation document must name this project's exact regional `agora-json-keys-grpc`
pipeline and target. Google project-ID and numeric resource names are accepted only within that
authorized pair; the output uses the numeric name required by the SDK boundary. Deployment parameters
reuse the jobs' database, application identity, network and secret pins. The management project number
and receipt bucket derive from the already validated `MANAGEMENT_ID-NUMBER-tofu-state` convention,
not a second copied parameter map. No API resource, renderer, provisioner or submission is added.

The sensitive `release_request` output is a native `CreateReleaseRequest` object. After separately
approved activation, the trusted caller can export it with `tofu output -json release_request` to a
private file and pass that file unchanged to the existing source publisher and submitter. JSON output
reveals sensitive values; keep the file, saved plan and state private and out of public logs. The caller
must select the exact reviewed configuration/state, not read the newest output during a concurrent release.

This object describes configuration, not persisted submission intent, successful job execution or
approval. Complete-family/provenance and enabled-version checks, database/migration readiness,
same-service exclusion and the native submission reservation remain separate gates. A failed or
ambiguous submission never authorizes regenerating IDs or replaying migrations. There is still no
live caller; Authentication API support and production ownership transfer remain separate work.

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

The protected bootstrap workflow supplies selected-family provenance, exact job/API image binding,
enabled job-secret metadata checks and private saved-plan custody. Activation still requires
promoted image availability, effective runtime access, same-service exclusion and an isolated
interruption drill. It never transfers an existing resource owner.

## Inputs and execution boundary

`images` contains `migrations` and, for JSON Keys, `rotatekeys`. Each image must use its exact
service/job path in the selected project's regional `agora-production` repository. `secret_versions`
contains `postgres-password` and, for JSON Keys, `app-master-key`, with positive integer versions.
These HCL syntax checks do not establish producer provenance, enabled versions or ownership of an
address/subnet. The [bootstrap preflight](../../docs/runbooks/provision-service-projects.md#protected-service-job-bootstrap)
checks artifact evidence and secret metadata against protected inputs; network ownership and runtime
readiness remain activation prerequisites.

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
backend initialization. All resource tests are provider-mocked plans, covering both service contracts
and safety-sensitive invalid inputs. One provider-free, resource-free fixture module evaluates a small
document table; invalid documents receive matching hashes so contract rejection cannot be masked by a
checksum failure:

```sh
tofu -chdir=environments/service-release init -backend=false -input=false -lockfile=readonly
tofu -chdir=environments/service-release validate
tofu -chdir=environments/service-release test
```

The API output is compared as a whole to the same native request fixture exercised by the Go/SDK
submission tests. There is no second expected parameter map or test-only compiler. These tests
provide no live IAM, database readiness or migration-recovery proof. The
[pinned provider resource](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/cloud_run_v2_job.html.markdown)
owns configuration convergence. OpenTofu's [backend variables](https://opentofu.org/docs/language/settings/backends/configuration/#variables-and-locals)
bind the state prefix directly to the selected project without a backend-file generator.
