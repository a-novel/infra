# Persist and reconcile a native release submission

**Code-only JSON Keys pilot, disabled by default.** The protected `deploy-service` action connects
these adapters under one guard. Live use still needs the [activation gates](#before-live-use);
merging does not provision resources, enable the action or replace legacy production.

The guarded caller preserves intent, waits for rendering, executes one migration and tracks the
approval-required rollout. Google's clients own authentication, API decoding and operation waiting.
Cloud Deploy owns rollout execution; the caller cannot approve, advance, retry jobs or roll back.
Migration dispatch remains outside Cloud Deploy hooks.

## Guarded established release

The [service-release root](../../environments/service-release#guarded-operation-output) exports one
`release_operation` from independently approved, converged configuration. It includes exact native
job UIDs/templates, the complete image family pins, secret-version references, source commit and a
known verified predecessor. It is not a first-launch or job-update path.

The inactive `release.yaml` job builds reviewed tooling before private inputs or authentication.
It selects the registered JSON Keys project from protected `FOUNDATION_CONFIG`, binds
`SERVICE_RELEASE_OPERATION_JSON` to the workflow commit and a private-file checksum, and checks
producer provenance before requesting that project's release identity. After authentication it
also requires the promoted images; it never copies images or changes job specifications.

`infra service-release deploy FILE SHA256` holds the same persistent guard as service-root applies
and native scheduled rotation. It checks exact converged jobs and the predecessor's verified,
private serving revision, publishes source, waits for rendering, dispatches the migration once,
then creates and tracks the approval-gated rollout. The migration boundary repeats secret metadata
and job-template checks; neither job overrides nor automatic migration retry are allowed.

GitHub remains running through human approval/advancement and native candidate/stable verification,
within a single 30-minute deadline. The caller cannot approve or advance anything. A failure, missing
evidence or expired wait returns nonzero and keeps the guard; a workflow retry cannot adopt it.
Native Cloud Deploy remains the only API/traffic owner.

After rechecking actual traffic, job convergence and migration evidence, success writes
`services/PROJECT/production/native-success/RELEASE_ID.json` in the receipt bucket. It preserves the
approved configuration, guard generation and native release/rollout. Only acknowledged publication permits
deleting the exact guard generation. These **native completion records are not legacy recovery
receipts**. Recovery-reader support and a live interruption drill remain activation gates.

For an interrupted guarded release, start with the existing
[read-only operation inspector](../service-operations.md#inspect-an-interrupted-operation).
It binds stored completion to the selected guard and configuration without querying native services.
The reconciliation commands below inspect native progress separately; neither report authorizes
unlocking or retrying. Missing completion is not proof that deployment did not happen.
The inspector derives this exact record name from the guard and pins its generation before reading.
A lost write acknowledgement can leave a valid record even though the deploy invocation failed.
After the original workflow ends, the separately approved
[operation finisher](../service-operations.md#finish-a-successful-operation) repeats exact guard deletion
for recorded completion. If completion is missing, it reuses the ordinary writer's native success,
actual traffic, approved-job and saved migration checks before create-only publication and cleanup.
Missing migration evidence or uncertain native outcomes remain blocked; no deployment is replayed.

Keep `SERVICE_NATIVE_RELEASE_ENABLED` unset/false and the protected operation secret unset until the
separate activation review. The workflow retains global writer serialization. Standalone
`submit-release`, `submit-migration` and `submit-rollout` are unavailable. The commands below publish
source or reconcile existing work; they cannot start a deployment or provide a first-launch path.

## The private request

The trusted caller supplies the service project ID, numeric project number, region and management
receipt bucket **independently** of the request. Their syntax is validated, but their authorization
and project-number relationship must come from the reviewed foundation contract.

The input is Google's native
[`CreateReleaseRequest`](https://docs.cloud.google.com/deploy/docs/api/reference/rest/v1/projects.locations.deliveryPipelines.releases/create)
JSON, limited to 64 KiB. The [test fixture](../../internal/submission/testdata/request.yaml) illustrates
its fields in readable YAML; it is not a production configuration. The inactive
[service-release root](../../environments/service-release#native-api-request) now produces this native
object from the same approved foundation and inputs as the jobs. Its sensitive `release_request`
output exports directly as JSON, without a shell template or Go renderer. The guarded operation
embeds the same object; configuration output alone does not reserve intent or authorize submission.

| Field                                                   | Accepted contract                                                                                                                                                                                                                                              |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `parent`, `releaseId`, `release.name`                   | One predetermined release in the selected numeric project's `agora-json-keys-grpc` pipeline and region.                                                                                                                                                        |
| `requestId`                                             | Nonzero lowercase UUID, chosen once and retained.                                                                                                                                                                                                              |
| `release.annotations`                                   | Exactly `request-id` matching that UUID and `source-commit` containing the reviewed 40-character commit.                                                                                                                                                       |
| `release.skaffoldConfigUri`                             | `gs://BUCKET/services/PROJECT_ID/production/sources/COMMIT.tar.gz`.                                                                                                                                                                                            |
| `release.skaffoldConfigPath`, `release.skaffoldVersion` | `skaffold.yaml` and a reviewed numeric `x.y.z` pin; no floating default.                                                                                                                                                                                       |
| `release.buildArtifacts`                                | Only `service-json-keys`, bound to the selected project's promoted gRPC image digest.                                                                                                                                                                          |
| `release.deployParameters`                              | Exactly the [eight pilot parameters](../../deploy/cloud-deploy/json-keys/README.md#native-release-inputs). The account belongs to this project, network and subnet share a host/region, database IP is private IPv4, and secret versions are positive numbers. |

Unknown fields, output-only fields, policy overrides and `validateOnly` are rejected. No credentials
or secret payloads belong in this record. Parameter syntax does **not** prove enabled secret versions,
image provenance or ownership of the database IP. Source contents are checked separately below;
their continuing immutability depends on IAM and retention.

## Publish the reviewed source

After separate live approval and completion of the [activation gates](#before-live-use), publish the
source using the same native request that will be submitted:

```sh
infra publish-release-source \
  --project-id="${SERVICE_PROJECT_ID:?}" --project-number="${SERVICE_PROJECT_NUMBER:?}" \
  --region="${REGION:?}" --receipt-bucket="${RECEIPT_BUCKET:?}" \
  --source-dir="${TRUSTED_CHECKOUT:?}" "${PRIVATE_REQUEST_FILE:?}"
```

The protected caller must select the reviewed infra checkout and build its binary before protected
inputs or credentials exist. Its `HEAD` must equal the request's exact `source-commit`. Matching a
commit is **not** proof of review or repository authorization; the caller must establish those.

Only the committed `deploy/cloud-deploy/json-keys/skaffold.yaml` and `service.yaml` enter the archive,
at its root. The packager reads raw Git objects with replacement refs and lazy fetching disabled;
it never uses working-tree files, archive attributes, checkout filters or hooks. Each entry must be
a non-executable regular file, nonempty and at most 16 KiB. Local edits, untracked files and local
credential/request files are excluded. Go's standard tar/gzip writers produce deterministic bytes;
Cloud Deploy/Skaffold still owns rendering and parameter/image substitution.

The existing Storage client uploads to the request's commit-addressed source URI with
[`ifGenerationMatch=0`](https://docs.cloud.google.com/storage/docs/request-preconditions), then reads
that exact object back and compares its bytes. No archive is overwritten or extracted locally.
An already-present identical archive, including one whose upload acknowledgement was lost, is
successful publication. Missing/unreadable data or conflicting bytes stop. Retrying **source
publication** is safe under the required no-delete/retention policy; it cannot submit a release.
This does **not** change the no-replay rule for deployment intent or migrations.

Use the same reviewed tooling/commit for publication and submission. The source URI is not
generation-pinned by this request contract: publisher permissions must exclude overwrite/delete,
and lifecycle rules must preserve the object while any release can refer to it. The submission
read-back is not a lock against a privileged writer. Keep the archive private and grant the renderer
read access only to the selected source prefix.

## Submission contract

The guarded caller verifies the exact committed source before release-intent reservation or any
Cloud Deploy write. Source mismatch stops without submitting anything. It then creates
`services/PROJECT_ID/production/submissions/RELEASE_ID.json` in the private receipt bucket with
[`ifGenerationMatch=0`](https://docs.cloud.google.com/storage/docs/request-preconditions).
Only an acknowledged, new object permits **one** `CreateRelease` call. An existing object is a stop,
even if its contents match. An uncertain storage response also stops before Cloud Deploy is called.
There is no "read identical intent, then resend" path.

The returned operation name is stored separately as `RELEASE_ID.operation.json`, also create-only,
before waiting through the official client. Cancellation stops local observation, not the cloud
operation. Neither record is removed on failure. Errors contain fixed diagnostics, not provider
response bodies or request contents.

Rendering is not deployment success. The caller waits for rendering to finish before migration,
and tracks the subsequent rollout through verification and durable completion.

## Reconcile an interruption

Use the exact release ID printed at submission, with the same independently selected scope:

```sh
infra reconcile-release \
  --project-id="${SERVICE_PROJECT_ID:?}" --project-number="${SERVICE_PROJECT_NUMBER:?}" \
  --region="${REGION:?}" --receipt-bucket="${RECEIPT_BUCKET:?}" \
  "${RELEASE_ID:?}"
```

This path only reads the exact private intent and exact Cloud Deploy release. It compares the
submitted fields, ignoring native timestamps/render results, and reports current rendering state.
It does not need the local source checkout, list resources, choose the latest release, use the
operation record to resend, or write anything. It remains usable if the create response or
operation-record acknowledgement was lost. It reports the native render state, not source provenance.

| Evidence                             | Action                                                                                                                                       |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Matching release, rendering          | Reconcile the same ID later; do not submit again.                                                                                            |
| Matching release, rendered           | Rendering succeeded. Rollout, verification and final receipt remain separate obligations.                                                    |
| Failed render or abandoned release   | Inspect that release and the native render/build diagnostics; obtain a reviewed recovery decision.                                           |
| Missing or unreadable intent/release | Stop. Inspect private storage, IAM and native audit/operation evidence. A 404 or permission error is not proof that dispatch never happened. |
| Request/identity conflict            | Stop. Resolve the mismatch; do not overwrite records or accept an unrelated release.                                                         |

Google guarantees request-ID deduplication for **at least 60 minutes**, not indefinitely. This adapter
does not use that window as a retry loop: a persisted intent never authorizes a second dispatch.
Do not delete the reservation or invent a new UUID/release ID to recover an uncertain request.
A crash after reserving intent but before dispatch intentionally requires operator reconciliation.

## Run the exact migration once

The guarded caller requires the selected project's `agora-json-keys-migrations` job to match the
approved UID and full task configuration. It must be ready, use the release's runtime account and
the image's entrypoint, and have one task, explicit zero retries and the root's 600-second timeout.
The complete image family and enabled secret metadata are checked before dispatch.

It reserves `RELEASE_ID.migration.json` under the private submissions prefix, binding the native
release UID and observed job snapshot.
Only a confirmed new reservation permits one native
[`RunJob`](https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs/run)
request, with the observed etag and **no overrides**. The pinned client does not retry that request.
An existing intent always stops, including after a lost storage acknowledgement.

The returned operation and any available execution identity are stored in
`RELEASE_ID.migration.operation.json` before waiting. Completion must identify the exact job and
acknowledged execution, preserve its task configuration, and report one successful task with no
failure, cancellation or retry. The native successful execution is retained create-only in
`RELEASE_ID.migration.execution.json`; identical read-back establishes publication even after a
lost write acknowledgement. The caller then proceeds to rollout while retaining service admission.

## Reconcile a migration interruption

```sh
infra reconcile-migration \
  --project-id="${SERVICE_PROJECT_ID:?}" --project-number="${SERVICE_PROJECT_NUMBER:?}" \
  --region="${REGION:?}" --receipt-bucket="${RECEIPT_BUCKET:?}" \
  --timeout=15m "${RELEASE_ID:?}"
```

This reads the reserved job/release binding and reconnects to the **recorded operation** through
Google's bounded waiter. It never executes, updates or cancels a job. Unlike release/rollout
reconciliation, it may publish the immutable successful-execution record. That requires scoped
create/read permission on private evidence, but no job-execution permission.

Lost dispatch responses without a saved operation, unavailable/expired operations, failed executions
and conflicting evidence require manual audit. Cloud Run has no caller request-ID field for `RunJob`.
Do not select the latest execution, erase intent, change release IDs or rerun migrations to recover.
A timeout stops local waiting, not a cloud execution. Reconciliation does not inspect the job's latest
configuration: it compares the exact operation result against the immutable pre-dispatch snapshot.

Retain all three records with the release. A completed execution record can gate rollout submission
without querying an old operation; a missing record cannot be reconstructed after native evidence
expires. No automatic database backup restore or schema rollback is performed.

## Submit the approval-gated rollout

The guarded caller uses the independently approved rollout UUID, distinct from the release UUID.
It requires the native release to match its private intent and finish rendering. It validates
the three migration records and their successful execution before reserving rollout intent. Missing,
failed or mismatched migration evidence stops without creating a rollout. Both its target snapshot
and the current target must require approval, identify the same target UID, and
point to the selected project's Cloud Run location. These reads are preflight checks, not a lock
against privileged target changes; configuration ownership and IAM must enforce that boundary.

The native request fixes the rollout ID to `production`, the target to `agora-json-keys-grpc` and the
starting phase to `canary-0`. It binds the native release UID and request UUID. There are no target,
phase or policy-override flags. The request is reserved once as
`services/PROJECT_ID/production/submissions/RELEASE_ID.rollout.json`; the operation name follows in
`RELEASE_ID.rollout.operation.json`. Both use the same create-only rule as release submission.
Changing the request UUID cannot bypass an existing reservation.

The caller keeps waiting during human approval and stable-phase advancement, within its deadline.
An interrupted wait leaves the guard held; do not rerun deployment to clear it. Cloud Deploy can skip
the candidate phase on first launch, so the caller requires a verified compatible predecessor.

## Reconcile the rollout

```sh
infra reconcile-rollout \
  --project-id="${SERVICE_PROJECT_ID:?}" --project-number="${SERVICE_PROJECT_NUMBER:?}" \
  --region="${REGION:?}" --receipt-bucket="${RECEIPT_BUCKET:?}" \
  "${RELEASE_ID:?}"
```

This reads the release intent, release, rollout intent and exact `production` rollout. It validates
their binding, including the native release UID, then uses the [observer's completion checks](observe-rollout.md).
It remains usable after a lost create response or operation-record acknowledgement. Missing records,
identity conflicts and unknown outcomes stop without resubmitting or modifying anything.

Approval, phase advancement, progress, failure and interrupted observation return nonzero.
Zero means both candidate and stable deployment/verification succeeded; the final durable recovery
receipt is still a separate completion obligation. For bounded continuous tracking after approval,
the existing `infra observe-rollout` command accepts the exact resource name printed here.

## Before live use

The [service-operation contract](../service-operations.md) maps the remaining ownership and recovery
work. The protected caller now connects native submission and completion under one service guard;
local tests do not establish effective cloud permissions, API normalization or recoverability.

The remaining work in [#189](https://github.com/a-novel/infra/issues/189) and
[#187](https://github.com/a-novel/infra/issues/187) must establish:

- Independently approve the exact HCL output only after foundation/job convergence and database
  readiness. The protected workflow checks registration and pins; it does not grant approval to a
  hand-written configuration or establish service-maintainer migration compatibility.
- Keep source, intent and
  operation objects private, non-overwritable and non-deletable by submitters; lifecycle must not
  discard them while an identity can be reused.
  Cloud Deploy's renderer needs read access to the exact source prefix, not receipt-write access.
- Retire all direct/legacy mutation paths before relying on guarded rotation. Account for previously
  accepted executions, shared-root writers and console authority; a paused schedule alone is not
  proof of quiescence. Keep job configuration under its single OpenTofu owner.
- Prove native completion consumption by recovery and protected handling of interrupted operations,
  missing completion records and lost unlock acknowledgements. Rendering or a green workflow alone
  is not recoverability evidence.
- A known compatible predecessor for routine releases, with separate bootstrap handling. Approval
  and advancement must retain same-service exclusion and cannot bypass failed verification.
- Least-privilege identities, the one-writer OpenTofu/Cloud Deploy handoff, and a human-approved
  interruption drill that verifies actual API normalization, IAM and receipt recovery.

Legacy release behavior, receipt formats, production resources and Renovate settings stay unchanged.
