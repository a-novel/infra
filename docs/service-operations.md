# Service-operation contract

**Contract for the inactive service-owned pilot, not a production guarantee.**
This contract advances [interrupted-release recovery](https://github.com/a-novel/infra/issues/189)
and [ownership transfer](https://github.com/a-novel/infra/issues/187). Implementation and live
activation remain separate review gates.

## What exists, and what is missing

The current [foundation](../.github/workflows/foundation.yaml) and
[release](../.github/workflows/release.yaml) workflows serialize production writes through
`production-infrastructure`. Keep that working boundary until every replacement writer participates.
The pilot's [guarded caller](runbooks/submit-release.md#guarded-established-release) preserves immutable
intent and dispatches native work under the same service guard as service-root applies and native
rotation. Standalone commands only publish source or reconcile recorded outcomes. Unenrolled
legacy/shared-root writers and protected recovery still prevent activation.

An **operation** is one reviewed change to one service, including the work needed to leave it in a
known state. A **guard** admits that operation and blocks another. A **request intent** prevents replay
of one mutation. Native **execution evidence** establishes what actually happened. None substitutes
for the others, and successful rendering is not a completed deployment.

### Implemented: service-root apply

The protected foundation workflow uses `infra custody plan apply` for both `service-foundation`
and create-only `service-release` bootstrap. It validates registration, activation and workflow
identity, snapshots the private inputs, and verifies their exact hash against the saved plan.
It then acquires the shared service guard before consuming the plan, applying it and checking
zero-change convergence. Neither root can publish configuration through the standalone
`infra custody config publish` command.

On success, the same process creates the converged configuration in its existing namespace,
then an immutable completion object at `services/PROJECT/production/operations/GENERATION.json`
in the receipt bucket. The record binds the reviewed plan/input hashes, workflow run/attempt,
acknowledged guard generation and configuration generation. **This proves apply convergence,
not application health or a completed release/recovery.** Only then may the process delete its
exact live guard generation. These writes use the existing foundation bucket authority.

Any failed or uncertain step after admission leaves the service blocked. A lost delete response
also returns non-success even if removal committed; inspect the exact completion and generation,
not just the workflow status. Cancellation stops local child processes but cannot recall accepted
cloud operations. There is no force-unlock, takeover, expiry or automatic apply retry. The protected
[finish operation](#finish-an-already-recorded-operation) can repeat only the final guard deletion after
verifying recorded convergence and a completed original workflow attempt. Read-only
assessment/drift refuses either service root while a guard is present, including before first state.

Protected applies and the [native rotation dispatcher](../modules/service-job-access#guarded-rotation)
now share admission with the [guarded established-release caller](runbooks/submit-release.md#guarded-established-release).
It holds the guard through source/render, one-shot migration, human approval/advancement, native
verification, actual-traffic checks and immutable native completion. It leaves guarded rotation's
schedule unchanged instead of adding another pause/resume controller.

Native completion has a distinct `native-success/RELEASE_ID.json` namespace in the service receipt
folder. The validated guard supplies the exact record name; the inspector pins its Storage generation
and verifies that the record belongs to that guard and configuration. The protected finisher can
clean up the guard after the original writer ends, including after a lost completion-write acknowledgement.
If native completion is missing, that same finisher can prove exact native success and publish it
without replaying deployment. These are not legacy recovery receipts; restore consumption still
requires implementation, and live activation requires an approved drill.

All pilot activation flags remain off by default; legacy production retains its existing global
serialization and configuration/receipt owners. Do not activate competing writers on this basis.

<a id="inspect-an-interrupted-apply"></a>

### Inspect an interrupted operation

From clean, current `master`, dispatch the read-only inspector:

```text
go run ./cmd/infra drift inspect-operation <json-keys|authentication> [guard-generation]
```

Approve the run's `production-foundation` environment review. This makes protected registration
available, but the job authenticates as the **read-only plan identity**, not the foundation writer.
It selects the registered project before authentication and publishes only the payload-free report
in the job summary. Its separate concurrency group remains available while a writer is blocked.

Before first use, a separately approved foundation apply must establish the declared
[completion-record read grant](../modules/workload-project/README.md#release-boundary).
Merging this code does not provision that grant or activate any writer. Inspection needs no mutation
enable flag; a service must already be registered in protected `FOUNDATION_TFVARS_JSON`.

An approved read-only session can also use the trusted binary directly, with protected
`FOUNDATION_CONFIG` registration and `MANAGEMENT_PROJECT_ID` already selected:

```text
infra custody operation inspect <state-bucket> <registered-project> [guard-generation]
```

Omit the generation to inspect the live guard. After a lost removal acknowledgement, supply the
guard generation acknowledged in the apply, native-release or rotation record; removed versions remain readable
subject to the bucket's retention/lifecycle policies. If admission itself was not acknowledged, inspect the live guard
without treating its presence as permission to adopt it. Do not substitute configuration from
candidate code or print the protected registration.

The command uses Google's existing authentication/client and needs only object reads on the selected
guard, completion and configuration records. Native release and rotation records also need the declared
service-local `native-success/` and `rotations/` read grants, provisioned by a separately approved foundation apply.
The inspector requests read-only Storage scope, checks registration
before credentials, and never requests write authority.

The report separates the live guard state from recorded convergence. It verifies the exact guard
bytes/generation, completion intent, and referenced configuration generation/hash. Downloads are
bounded and generation-pinned; denied, malformed, missing referenced versions or changing guard
observations return non-success without private payloads. A successfully observed missing completion
is reported as incomplete, not as proof that no resources changed.

For `native-release`, the report identifies the original workflow attempt and exact release/rollout.
It checks the stored configuration hash, completion's guard generation, native request identity,
and recorded render, approval, candidate and stable verification. Inspection works with the writer
disabled and a newer master commit; it uses the recorded source commit. It does not fetch current
Cloud Deploy/Run status or migration executions. Use the separately authorized
[rollout observer](runbooks/submit-release.md) for current native progress. A missing native completion
record leaves the operation incomplete. Earlier native records retain the same schema; their separate
`operations/` pointers are no longer read or written. Existing pointers remain stored, and apply
completion records in that namespace keep their current contract.

For `scheduled-rotation`, inspection binds the JSON Keys dispatcher execution/revision and guard
generation to `rotations/WORKFLOW_EXECUTION_ID/success.json`. It validates the recorded native operation,
rotation execution and completion time, without querying Workflows or Run. A missing success record
means incomplete, even if the job may have run. This proves recorded rotation success, not current
key availability or application health.

Exit zero means **inspection succeeded**, not that deployment succeeded or the service is safe to
unlock. A retained record proves historical convergence only: current health, native operations and
the previous writer still need protected reconciliation. An absent live guard proves no earlier
outcome, and another live generation belongs to a separate operation. The command never unlocks,
repairs evidence or retries apply. See [Storage version selection](https://docs.cloud.google.com/storage/docs/json_api/v1/objects/get).

<a id="finish-an-already-recorded-apply"></a>
<a id="finish-an-already-recorded-operation"></a>

### Finish a successful operation

This **off-by-default** path finishes converged service-root applies, successful native JSON Keys
releases and successful rotations. Native releases and acknowledged rotations can reconstruct a
missing completion record from exact native success evidence. Applies without recorded convergence,
unacknowledged rotations and unknown record kinds remain blocked.

After inspecting the exact generation, separately approve `SERVICE_OPERATION_RECOVERY_ENABLED=true`
in the `production-foundation` environment. From clean, current `master`, select the service and
generation reported by the inspector:

```text
go run ./cmd/infra foundation finish-operation <service> <guard-generation> 'FINISH <service> <guard-generation>'
```

The operation kind and any apply root come from the verified record. Direct workflow dispatches must
leave `root=none` and `plan_id` empty; extra selectors fail before authentication.
Approve the protected run. It uses the existing foundation identity and writer concurrency; it does
not run OpenTofu, publish configuration, execute jobs or mutate Cloud Deploy/Run. Current bootstrap inputs,
images and secret availability are not needed. It verifies the same immutable evidence as inspection.
Applies and native releases then require the [original GitHub run attempt](https://docs.github.com/en/rest/actions/workflow-runs#get-a-workflow-run-attempt)
to be completed and bound to the recorded commit and protected workflow action. Apply records bind
the root/service to `foundation apply`; native records bind the exact `release.yaml` attempt to
`production deploy-service`. The attempt may have failed after recording success; its conclusion
is not used as completion evidence.

Rotation instead reads the [exact Workflows execution](https://docs.cloud.google.com/workflows/docs/reference/executions/rest/v1/projects.locations.workflows.executions/get),
requesting only state, end time and revision. Its recorded revision must match and the original
dispatcher must have ended: `SUCCEEDED`, `FAILED` or `CANCELLED`. That proves the writer has stopped;
the separate success record proves rotation succeeded. Failure/cancellation may follow successful
publication. Active, unknown, denied or expired execution metadata cannot unlock the service.
The declared `workflows.executions.get` permission needs a separately approved foundation apply and
effective-permission check before use. This path never retries rotation.

If rotation success was not published, finishing also reads the generation-pinned reservation and
RunJob acknowledgement. Both must belong to the held guard. The reserved job UID, generation and
pinned image must still match the job obtained from the authorized project. The completed native
operation must return that job's exact execution and template, with one successful task and no
running, failed or cancelled tasks. RunJob can change the job's ETag through status updates; recovery
binds configuration through UID, generation and task template instead.

The existing `run.jobs.get`, `run.operations.get` and receipt-write permissions suffice: Google's
typed operation response supplies the execution without another execution lookup. After rechecking
the live guard, recovery publishes the same create-only success record as the dispatcher, then removes
only that guard generation. Missing acknowledgement, changed job configuration or unavailable native
evidence remain blocked; there is no fallback to a latest execution or another rotation attempt.

When completion already exists, the only write is deleting the current guard with its exact
[generation precondition](https://docs.cloud.google.com/storage/docs/request-preconditions). An
already-absent guard is a verified no-op. This path checks historical success and writer termination,
not current application health.

When native completion is missing, the original guard must still be live. Before any write, the shared
completion proof checks the exact saved request and native release/rollout, successful candidate and
stable verification, settled private service with all ordinary traffic on the verified revision,
approved live job UIDs/templates and saved successful migration evidence matching that approved job.
The finisher then creates the same `native-success/RELEASE_ID.json` with `ifGenerationMatch=0`, and only
an acknowledged write permits exact guard deletion. It neither overwrites completion nor reconstructs
missing migration evidence. The existing foundation role declares the three additional metadata reads
(`clouddeploy.releases.get`, `clouddeploy.rollouts.get`, `run.services.get`) in the selected workload
project; a separately approved foundation apply and effective-permission check must precede live use.

A successor/absent guard cannot repair missing completion. Active/unknown original attempts, native
failures or identity conflicts, unavailable evidence and uncertain writes leave admission blocked.
Reinspect the same generation after an uncertain result: a lost publication acknowledgement may have
saved valid completion, allowing the recorded-cleanup path next time. Archived evidence is never
deleted. Turn the recovery flag off after the approved operation and review the outcome before admitting
another change. This is not a general repair/retry engine or a legacy data-recovery receipt.

The command cannot fence console administrators or unenrolled writers. If other native work may still
be running, keep the service blocked and reconcile it separately. Retained records and effective IAM,
native API normalization and interruption recovery still require a human-approved activation drill.

## One owner for each responsibility

| Responsibility                                                         | Owner                          | Boundary                                                                                                    |
| ---------------------------------------------------------------------- | ------------------------------ | ----------------------------------------------------------------------------------------------------------- |
| Projects, IAM, private networking, database hosts/disks                | Protected OpenTofu foundation  | Participates in exclusion for every affected service; not routine release authority.                        |
| Selected application job specifications                                | OpenTofu service-release state | Bootstrap is create-only today; routine updates need an explicit writer handoff.                            |
| Rotation schedule definition and invocation IAM                        | OpenTofu service foundation    | Creates paused; later pause/resume belongs to operational control, not foundation convergence.              |
| Scheduled rotation admission, dispatch and completion                  | Google Workflows               | Fixed service/job; same persistent guard, single submission, immutable evidence before release.             |
| Migrations and rotation executions                                     | Cloud Run Jobs                 | Caller controls admission and records exact execution evidence; migrations remain outside retry hooks.      |
| Complete API specification, revisions, traffic, deploy/verify progress | Cloud Deploy                   | Sole API writer after handoff; no parallel Go traffic controller.                                           |
| Admission and final evidence                                           | Small trusted Go caller        | Reuses native adapters; no duplicate rollout controller or schedule toggle loop.                            |
| Review, bounded tracking and operator handoff                          | GitHub Actions                 | Waits for the exact deployment and verification; reports required action or unknown outcome as non-success. |
| Alerts when the runner is unavailable                                  | Native Google Cloud monitoring | Notification is not recovery evidence or authority to release a guard.                                      |

The dormant pilot database is still foundation-owned. This contract does not authorize a routine
writer to change its metadata or declare it ready. Database activation, backup proof and maintenance
ownership remain gates in the [service-foundation contract](../environments/service-foundation/README.md).
Application compensation never restores an old database backup or reverses concurrent writes.

## Use existing mechanics; add only service admission

| Existing mechanism                                                                                                                      | Keep it for                                | Why it does not cover the whole operation                                        |
| --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | -------------------------------------------------------------------------------- |
| [GitHub concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency) | Serializing live trusted writer jobs       | Its lifecycle is the GitHub job/run, not accepted work still running in Google.  |
| OpenTofu backend lock                                                                                                                   | Protecting one state transaction           | Separate roots and post-apply migrations/rollouts are outside that lock.         |
| [Cloud Deploy](https://docs.cloud.google.com/deploy/docs/architecture)                                                                  | Native rollout execution and recovery      | It does not own foundation changes, external migrations or our recovery receipt. |
| Immutable release/request intents                                                                                                       | One-shot dispatch and later reconciliation | Another release ID can reserve different intents for the same service.           |

The admission primitive is **one persistent guard object per service**, using the existing official
Storage client. Its location is `services/PROJECT_ID/release/operation.json` in the state
bucket, inside the service's existing release-state namespace. It is not a receipt, Terraform state
or renewable lease. No new database, queue or expiry worker is needed.

Acquire with [GCS generation preconditions](https://docs.cloud.google.com/storage/docs/request-preconditions):
create only when no live object exists, then retain the returned generation. The small, private record
binds the approved project/service/region and its owner: commit/GitHub run/attempt for applies and
releases, or native workflow execution/revision for scheduled rotation. A release also binds its
predetermined release ID. It contains no credentials or secret payloads. A new automated operation
needs an acknowledged acquisition before dispatch. A lost acknowledgement requires reconciliation, not a second
acquisition or automatic adoption of matching content.

The guard has **no TTL, automatic takeover or unconditional cleanup handler**. Finishing deletes only
its exact generation, after the completion conditions below. An ambiguous delete is resolved by
inspecting that generation and its completion evidence, never by deleting the current object by name.
Native generation checks provide the storage primitive; Agora retains only the admission policy.

This is a cooperative trusted-tooling boundary, **not fencing of other cloud APIs**: a GCS generation
cannot invalidate a delayed Cloud Run or Cloud Deploy request. All mutating callers must participate.
Privileged console access and IAM administrators remain explicit human coordination boundaries.

## One operation from admission to completion

1. **Authorize and admit.** Resolve the reviewed service/foundation, exact images and provenance,
   enabled secret-version metadata, and intended operation. Enter the writer concurrency group and
   acquire the guard before changing managed resources or executing work. Repeat checks at their consumption
   boundaries; the guard cannot prevent an administrator changing a secret version.
2. **Exclude competing scheduled work.** Native rotation holds the same guard from admission through
   execution and evidence, so a routine release leaves that schedule unchanged. This is safe only
   after all direct/legacy dispatch paths are retired and their accepted executions reconciled.
   Otherwise pause/drain remains a prerequisite: neither a paused schedule, an acknowledgement nor
   one empty execution list proves quiescence. Never touch an unrelated service's schedule.
3. **Execute through the existing owners.** Apply only the selected reviewed plan; bind submission
   to its converged job configuration. Persist request intent, dispatch a migration once, then require
   its exact successful evidence before rollout. Cloud Deploy owns deployment/verification/traffic;
   approval and advancement stay within this operation's exclusion. Unknown outcomes stop progression.
4. **Record and finish.** Verify the exact candidate and stable phases, publish the immutable recovery
   receipt, then confirm the intended compatible schedule state. Publish immutable operation-completion
   evidence binding the guard generation to the settled native work and receipt. Only then release
   that generation. A missing receipt is repaired from evidence, not by rerunning deployment.

Failure or cancellation uses the same completion boundary, not a success-only unlock shortcut.
Completion evidence must distinguish success, no mutation dispatched, and a reconciled failure.
It identifies the final serving/configuration state, settled operation-owned and pre-pause executions,
and intended schedule state. Pending approvals or ambiguous operation dispatches cannot be treated as
settled. Compatible periodic work may resume at step 4; it is not unfinished deployment work. A migration
failure may need service-maintainer intervention; neither retry nor data rollback is automatic.

## Interruption decisions

| Observation                                                       | Safe next action                                                                          | Guard                                    |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------- |
| Another operation already owns the service                        | Report its identity and reconciliation path; do not mutate.                               | Retained by its owner.                   |
| Runner lost, timed out, or dispatch acknowledgement lost          | Inspect the same stored intent and native operation; do not infer failure or replay.      | Retained.                                |
| Approval/advancement pending or verification failed               | Report the exact rollout and required action; keep automatic advancement/repair disabled. | Retained.                                |
| Deployment healthy, receipt or schedule reconciliation incomplete | Repair only the missing evidence/control step after reconciling its outcome.              | Retained.                                |
| Known failure safely reconciled, or no mutation was dispatched    | Record the terminal outcome and final state; no automatic database restore.               | Release exact generation after evidence. |
| Completion recorded but guard deletion acknowledgement lost       | Read the guard generation and completion record; never remove a successor's guard.        | Reconcile exact generation only.         |

Observation-only commands and narrowly scoped evidence publication must remain available while a
writer is blocked. Do not put the observer behind the writer's concurrency group.

Protected recovery is a separately approved way to finish the recorded operation under its held
guard, not automatic adoption by another runner. It must establish that the previous writer cannot
issue more requests and reconcile accepted cloud work before further mutations. Record its settled
outcome before releasing the guard or admitting a new operation. Cancelling a runner alone is
insufficient: credentials, delayed requests and executable
pending rollouts matter. If their status cannot be established, keep the service blocked. Never
force-unlock merely because a run is old or a health check currently passes.

## Enrollment before activation

- Enroll **every writer**, not just the submission CLI: foundation and job bootstrap/update,
  database maintenance, migration, manual rollout progression, schedule control and receipt completion.
  Retain global infrastructure serialization until shared operations can acquire all affected service
  guards in a stable order, without mutating under a partial acquisition. Do not partially activate
  per-service concurrency beside an unenrolled legacy writer.
- Review narrow guard permissions for maintenance/recovery principals; existing foundation authority
  does not imply access to service release state. Keep the guard out of the locked-retention receipt
  bucket. Exclude it from artifact lifecycle cleanup. Teach the existing
  [state inventory](../internal/inspection/services.go) its exact identity and blocked meaning rather
  than ignoring arbitrary unexpected objects or backend locks.
- The [foundation configuration](../modules/service-job-access/rotation.tf) creates schedules paused
  and ignores only subsequent `paused` changes. Preserve this ownership boundary and safe bootstrap
  ordering; prove accepted-request draining before enabling any operational resume authority.
- Bind complete configuration/provenance, durable receipts and effective IAM in one protected caller.
  The service release federation currently permits the exact `release.yaml` workflow; splitting
  workflows requires a reviewed identity change, not just a new filename.
- Keep first launch and state ownership transfer separate from routine release. Remove the old API
  specification/traffic writer only after its native replacement and recovery evidence are proven.

## Implementation and retirement gates

Deliver admission and completion with all participating callers, not another standalone helper that
leaves safety to undocumented callers. Keep native SDK waiting and Cloud Deploy recovery; test the
small decision boundary with table cases for competing owners, lost acknowledgements, ambiguous
execution, missing receipts and stale-generation cleanup. Do not recreate a fake cloud in unit tests.

The inactive JSON Keys workflow now connects the native path without activating it. Its native
completion still needs restore consumption; unacknowledged rotations and incomplete applies need separate reconciliation.
Recorded-success cleanup uses the protected finisher above. A separately approved
interruption/cutover drill must prove service isolation, scheduled-work exclusion,
credential boundaries, operator recovery and receipt repair. Only that evidence permits replacing
the corresponding legacy orchestration and its tests. Peer deployments and Renovate remain unchanged.
