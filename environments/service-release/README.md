# Single-service release root (inactive)

This root owns one service component's Cloud Run jobs, API revisions and explicit traffic targets.
In private or dedicated scope, JSON Keys has migrations and rotation; Authentication has migrations.
Public-api scope owns its API and no jobs.
The shared resource pattern derives the application identity and
database endpoint from the [foundation's published document](../service-foundation#published-coordinates).
OpenTofu validates its checksum and service scope against independently approved inputs. Shared VPC
coordinates, promoted image digests and numeric secret versions remain separate inputs. Neither this
root nor its future caller needs foundation-state access.

**Code only:** trusted assessment and drift can inspect this root. The protected
[job bootstrap](../../docs/runbooks/provision-service-projects.md#protected-service-job-bootstrap)
is disabled by default. Shared API deployment is not yet enrolled in the protected workflow.
Applying a job specification does not run it. With `api = null`, the root creates no API. Foundation
owns databases, IAM, schedules and alerts. Existing production resources and state stay unchanged.

## State and resource ownership

The [workload project](../../modules/workload-project) publishes the service's release identity and
`release.state` coordinates. Set `state_bucket` to that published bucket; the native GCS backend
derives `services/PROJECT/release/` for dedicated scope or
`workloads/production/ZONE/PROJECT/SERVICE/release/` for shared scope. Only the default workspace
is accepted, with `default.tfstate` below that prefix. The provider uses that same project
and region. Inputs contain numeric secret versions and approved coordinates, never payloads.

The bucket check constrains its management-project naming convention, not its ownership. The future
protected caller must authorize inputs against the published coordinates before initialization, use a
fresh working directory, and prohibit backend overrides. Keep credentials in the approved federation
environment. [GCS locking](https://opentofu.org/docs/language/settings/backends/gcs/) covers OpenTofu
operations; migrations and traffic promotion still require the broader same-service exclusion.

## Read-only assessment and drift

The existing inspector selects projects from the last converged shared-foundation registration.
It inventories native managed-folder metadata under `services/` and `workloads/`, then reads objects only within each
registered release folder. The plan identity's existing folder-scoped access is
sufficient; no bucket-wide object grant is required. Missing or unregistered folders stop inspection.

The shared foundation's `service_release_zones` enrolls
`workloads/production/ZONE/PROJECT/SERVICE/release/` folders for private/public-api boundaries.
Enrollment accepts empty folders and exact saved-plan artifacts. Existing state, configuration or
other objects stop inspection pending an approved ownership handoff. Protected mutation callers
remain dedicated-project-only; an API registration never activates database jobs.
The platform-only public zone cannot enroll these backend services. Historical public custody paths
remain readable, but an old public registration must undergo an explicit ownership handoff rather
than being silently reinterpreted as public-api.

A confirmed empty folder is skipped. Initialized state requires its matching converged inputs at
`services/PROJECT/release/config/RUN-ATTEMPT.tfvars.json`, using the existing zero-padded sequence format.
Missing inputs, inputs without state, a held service-operation guard, unexpected workspaces/locks
and denied reads stop inspection.
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
The same custody format supports shared release folders under
`workloads/production/ZONE/PROJECT/SERVICE/release/`. Its exact scope remains bound in metadata;
foundation and recovery roots cannot use that namespace. Configuration reads support the same
boundary, while configuration publication and shared-zone apply remain blocked.

For both service roots, `publish` and `fetch` require the private tfvars filename as their **last** argument,
after the existing arguments (`publish`: bucket, root, commit, plan ID, plan file, destructive marker;
`fetch`: bucket, root, commit, plan ID, destination). Both bind the exact input bytes by SHA-256.
Changing even formatting requires a new plan. Missing or different inputs stop before the opaque plan
is downloaded. Root/project/commit/sequence, checksum, deletion marker and the 24-hour expiry retain
their existing checks. Legacy plan paths and metadata remain compatible.

Publication is create-only. A lost upload acknowledgement or partial publication stops; inspect the
exact objects rather than overwriting or assuming no upload occurred. `consume` retains its existing
arguments and removes the selected pair before apply. A failed or ambiguous consumption
must block mutation. The provider owns state locking. The protected workflow retains global
infrastructure serialization and uses [guarded service-root apply](../../docs/service-operations.md#implemented-service-root-apply)
through convergence, configuration and completion publication. Standalone service configuration
publication is refused. Rotation uses the same guard; shared-root ownership transfer and
interrupted job recovery remain separate work.

Metadata enforces the 24-hour apply deadline. Bootstrap declares native
[plan cleanup](../../bootstrap/README.md#plan-artifact-expiration) after age 2 days, with separate
rules for dedicated-service, production private/historical-public and public-api prefixes restricted to
the two artifact suffixes. Cleanup is asynchronous and keeps seven-day soft delete. The
[plan policy](../../ops/README.md#protected-workflow-operations) requires existing Delete rules to stay
unchanged; deletion approval cannot bypass that protection.
Protected bootstrap apply and live verification remain prerequisites before writer activation.
`SERVICE_JOB_BOOTSTRAP_ENABLED=true` permits only create/no-op plans for this service's exact
application jobs. Updates, imports, moves, replacements, deletions and other resources fail regardless
of deletion approval. Routine job updates remain disabled.

## Approved foundation handoff

`zone = "private"` prepares the schema-2 shared-service job contract. It accepts the
[existing-database handoff](../service-foundation#existing-private-database-handoff) only through
that private scope's approved runtime document. The native backend derives
`workloads/production/private/PROJECT/SERVICE/release/`; application images use
`agora-SERVICE-private-production`, and jobs attach the existing `agora-SERVICE` network tag.
Its optional `api` selects JSON Keys gRPC. `zone = "public-api"` prepares JSON Keys REST
or Authentication REST and requires an independently approved `private_project_id`.
The database reference must belong to that private project and the same service; its Shared VPC
network must also belong to that project. Both JSON Keys APIs consume one private database;
Authentication consumes its own. Public-api creates no database or job resources.
The platform-only `public` zone is rejected.

This contract is cloud-blind preparation: existing job names still have their legacy owner.
Reconcile exact resource/state ownership and enroll the protected writer before applying it.
The current bootstrap and routine mutation guards still reject shared release state.
The following dedicated-project handoff remains unchanged when `zone = null`.

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
   foundation snapshots taken before database provisioning are rejected.
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
Automatic reference approval remains deliberately absent.

| Root resource address                               | Owner and lifecycle                                                                   |
| --------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `google_cloud_run_v2_job.application["migrations"]` | Selected service's migration specification; never dispatched by apply.                |
| `google_cloud_run_v2_job.application["rotatekeys"]` | JSON Keys only; rotation specification, independent of its foundation-owned schedule. |

Both jobs have provider deletion protection and `prevent_destroy`. Updating a specification affects
subsequent executions, not already-running tasks. The inactive root allocates nothing today; once
activated, job execution and logging incur costs. Its version-1 `jobs` output contains names, UIDs and
images, not execution or health evidence. Dispatchers must inspect live definitions and retain native
operation/execution identities.

## API revisions and traffic

`api = null` keeps the existing jobs-only behavior. To prepare an API, provide its promoted `image`
digest, exact candidate `revision`, and exact healthy `serving_revision`. Private JSON Keys uses gRPC;
public-api uses REST. Shared images belong to `agora-SERVICE-private-production` or
`agora-SERVICE-api-production`, with the selected component's runtime identity and existing database.

OpenTofu owns the service specification and traffic in one state. A different candidate receives
zero ordinary traffic and the `candidate` tag; the named serving revision retains 100%. After
candidate health and migration checks, a separate reviewed plan sets `serving_revision = revision`.
Rollback selects the previous compatible serving revision. It never restores database contents.
The [release runbook](../../docs/runbooks/submit-release.md) describes this ownership boundary.

Private gRPC retains internal ingress and IAM authentication. REST exposes only its application API;
neither project membership nor a traffic tag authorizes access to the database or secrets.
Public JSON Keys receives only `postgres-password`. Authentication also requires
`smtp-sender-password` and its non-secret `authentication` settings. Optional `waitlist_url`
requires `waitlist-secret`. Public-api requires an empty job `images` map.

Capacity remains bounded at three instances, one CPU and 512 MiB per instance. Authentication keeps
instance-based CPU for accepted email work and its existing one-instance minimum. Private JSON Keys
keeps one warm instance; the prepared public JSON Keys API can scale to zero. Candidates and project
moves can still incur overlap cost: inspect existing capacity and the exact plan before activation.

The `api` output provides Cloud Run's service and candidate URLs, not health evidence.
Producer provenance, enabled secret versions, exact resource ownership, effective network access and
successful migration remain prerequisites. The committed image manifest does not yet enroll JSON
Keys REST; image preflight rejects that component until its producer family is explicitly added.
No protected API writer or first-launch shortcut is enabled by this preparation.

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

In private/dedicated scope, `images` contains `migrations` and, for JSON Keys, `rotatekeys`.
Each image uses its exact service/job path in the selected scope's regional production repository.
Those job scopes require `postgres-password` and, for JSON Keys, `app-master-key`.
Public-api follows the API contract above. All secret versions are positive integers.
These HCL syntax checks do not establish producer provenance, enabled versions or ownership of an
address/subnet. The [bootstrap preflight](../../docs/runbooks/provision-service-projects.md#protected-service-job-bootstrap)
checks artifact evidence and secret metadata against protected inputs; network ownership and runtime
readiness remain activation prerequisites.

Migrations mount only their PostgreSQL password reference. Rotation additionally mounts the master
key. Dedicated application identities retain their service-foundation grants, including Authentication's
SMTP permission; shared identities use the service/zone grants. Mounted references do not restrict
an identity's effective IAM. Payloads never
enter OpenTofu inputs or outputs.

Each execution has one task on 1 CPU / 512 MiB with the image's own entrypoint. Migrations have a
ten-minute timeout and zero task retries; idempotent rotation has five minutes and one retry.
Google's [task retry setting](https://docs.cloud.google.com/run/docs/configuring/max-retries)
does not prevent two separately dispatched executions. Keep same-service exclusion around job
updates, migrations, API rollout and receipt publication. Once every rotation dispatcher holds the
same guard until completion, the routine release can leave scheduling unchanged; existing direct
dispatch paths must first be retired and their accepted work reconciled.
An ambiguous migration dispatch requires reconciliation of its exact execution; neither a timeout
nor a missing receipt permits replay. Shared deployment remains disabled until the existing guard
and native execution evidence protect that boundary. Ownership transfer and recovery drills remain
activation prerequisites.

Both job types use all-traffic Direct VPC egress and their service's network tag. The host foundation
must provide private database access, restricted Google API routing and the Cloud Run service-agent
subnet grant. PostgreSQL keeps the existing private non-TLS transport contract. Verify effective
network and IAM denial, including peer database access, before activation.

Neither project-wide invoker grants nor legacy fleet invocation tags are copied here. Recovery into
another project uses its own approved restored-data path, not these production mutation jobs.

## Cloud-blind validation

The existing CI validation job runs this root directly with the committed provider lock and no
backend initialization. All resource tests are provider-mocked plans, covering both service contracts
and safety-sensitive invalid inputs. Provider-free, resource-free fixtures evaluate
document tables; invalid documents receive matching hashes so contract rejection cannot be masked by a
checksum failure:

```sh
tofu -chdir=environments/service-release init -backend=false -input=false -lockfile=readonly
tofu -chdir=environments/service-release validate
tofu -chdir=environments/service-release test
```

API tests inspect actual resource arguments, candidate/promotion traffic, secret separation and
capacity limits. They provide no live IAM, database readiness or migration-recovery proof. The
[pinned provider resource](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/cloud_run_v2_job.html.markdown)
owns configuration convergence. OpenTofu's [backend variables](https://opentofu.org/docs/language/settings/backends/configuration/#variables-and-locals)
bind the state prefix directly to the selected project without a backend-file generator.
