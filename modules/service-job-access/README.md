# Service application job access

Protected foundation owns access to existing [application jobs](../../environments/service-release), schedules and alerts.
The module consumes the [service foundation's](../../environments/service-foundation) versioned `runtime` contract.
It derives fixed job names and the project-local `infra-release` principal; callers cannot supply
another principal or extend the job set. The protected foundation workflow composes it after explicit
job bootstrap opt-in; the service pilot remains disabled by default.

| Grant                                   | Scope                                                                   |
| --------------------------------------- | ----------------------------------------------------------------------- |
| Job read/update and execution read/list | The selected service's migration job and, for JSON Keys, rotation job.  |
| Run Invoker                             | Those same jobs; no execution overrides or cancellation.                |
| Operation get                           | The service project, because operations live outside the job hierarchy. |
| Service Account User                    | The selected application runtime only.                                  |

Job creation/deletion and IAM changes remain protected operations. The release principal receives
no API, scheduler or rollout-probe mutation grant here. Cloud Deploy workers receive no grants.
The narrow custom roles complement Google's predefined invocation and identity-attachment roles;
the existing provider owns policy convergence. There is no additional script or dependency.

Job-update plus runtime attachment permits running code with the application's effective privileges,
including its secret access. It also permits changing job configuration such as retries and arguments.
The missing execution-override permission is not a defense against a malicious job writer. Keep image
provenance, reviewed configuration and the exact live-template check before dispatch. Project-level
operation reads cover other operations in the same service project too.

## Bootstrap and one-writer handoff

Bootstrap must establish the project, runtime and application jobs before applying this module.
The protected executor needs custom-role administration in the service project, IAM maintenance on
the exact jobs and runtime, and the separately approved permissions to create those initial jobs.
These grants do not add bootstrap authority to routine release.

Keep this module in protected foundation state. Bootstrap job specifications directly in the
service release root's destination state; an existing pilot owner requires a separately reviewed
state transfer with private backup and reconciliation. Routine release
must not apply foundation. If a job is missing, routine creation fails; reconcile it under protected
bootstrap authority. Existing registry, state and receipt access comes from the other service modules.
Shared VPC attachment and host-owned network-use permissions remain separate activation prerequisites.

Before activation, inspect inherited IAM and prove both permitted job operations and denied
probe/peer updates, creation/deletion, overrides, cancellation, IAM writes and attachment of another
runtime. Additive IAM members preserve other grants; these declarations cannot prove effective denial.
Use same-service exclusion for configuration, migrations and rollout. Reconcile an uncertain execution
against native operation/execution records before any retry. Migration dispatch remains outside
Cloud Deploy retry hooks.

## Guarded rotation

JSON Keys uses the native path **Scheduler → Workflows → Cloud Run Job**. Authentication creates
none of these rotation resources. Foundation owns their definitions and IAM; the service pilot
remains inactive and disposable recovery omits this module.

| Identity                    | Authority                                                                                                                       |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `agora-json-keys-scheduler` | Create workflow executions in this service project. No direct RunJob, execution reads or cancellation.                          |
| `agora-json-keys-rotation`  | Read/invoke the exact rotation job, read regional operations, manage the exact service guard, create private rotation evidence. |
| Application runtime         | Unchanged job identity, database and master-key access. The dispatcher cannot read those secrets or attach another runtime.     |

[Workflows IAM](https://docs.cloud.google.com/workflows/docs/access-control) is project-scoped.
The custom Scheduler role contains only `workflows.executions.create`; a future workflow in this
project would also be invocable. Review that trust before adding one. The broader predefined Invoker
role also allows cancellation and is not used here. Google's Scheduler and Workflows service agents
mint their respective tokens; only protected foundation may attach these exact runtime identities.

### Dispatch and completion

`rotation.yaml.tftpl` accepts no runtime parameters. It selects the fixed project, region and job from
protected foundation inputs and uses the same guard as [service applies](../../docs/service-operations.md):
`services/PROJECT/release/operation.json` in `state_bucket`. Acquisition creates the object with
`ifGenerationMatch=0`; a pre-existing guard returns `busy` without running a job. The guard identifies
the workflow execution/revision and has no TTL. Unacknowledged acquisition fails without adoption.

After admission, the workflow checks the converged single-task job, service runtime, pinned local
image and unchanged image entrypoint. It records job UID/generation/ETag and submits RunJob **once**
with that ETag and no overrides. Authenticated HTTP mutation calls have no retry policy;
[connectors retry writes automatically](https://docs.cloud.google.com/workflows/docs/connectors).
Only exact operation reads repeat. Observation stops on completion or a thirty-minute budget
(plus an in-flight read's native timeout/retries), retaining admission on uncertainty.

The returned operation name is recorded before waiting. Successful completion requires the exact
execution, one succeeded task and a successful Completed condition, with no
running, failed or cancelled tasks. Rotation retains its existing one-task retry policy; the
application must remain idempotent. These checks prove job success, not that a new key was needed.
The native [RunJob ETag](https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs/run)
binds dispatch to the inspected job version; the dispatcher has no override permission. There is no
second implementation of template comparison in the workflow.

Create-only evidence lives in the existing receipt bucket under
`services/PROJECT/production/rotations/WORKFLOW_EXECUTION_ID/{intent,operation,success}.json`.
It contains identities and configuration metadata, never secret payloads. Only acknowledged success
publication permits deletion of the acquired guard generation. Failures, cancellation, unknown
RunJob responses and failed evidence writes leave the guard held. Lost deletion acknowledgement
also fails even if removal committed. No error handler unlocks, retries execution or resumes Scheduler.

Scheduler uses a fixed OAuth request without arguments, hourly at `10 * * * *` UTC, with zero configured retries and
execution backlogging disabled. Its [at-least-once delivery](https://docs.cloud.google.com/scheduler/docs/overview)
can still create duplicates: concurrent executions compete for the guard, while a later duplicate
may rotate again after completion. This is serialization, not exactly-once delivery. A delayed
dispatcher must acquire current admission before RunJob; a paused schedule or empty execution list
is never used as proof of quiescence. Every other writer must enroll before activation.

### Inspect retained admission

Use an approved read-only session and the exact workflow execution ID from the guard or matching native log:

```text
gcloud workflows executions describe "${ROTATION_EXECUTION_ID:?}" --workflow=agora-json-keys-rotation --project="${SERVICE_PROJECT_ID:?}" --location="${INFRA_REGION:?}" --format='yaml(name,state,workflowRevisionId,status,startTime,endTime)'
```

The existing [operation inspector and protected finisher](../../docs/service-operations.md#inspect-an-interrupted-operation)
accept rotation records. Inspection verifies the exact saved success and guard generation without
native queries. Finishing additionally requires the original dispatcher revision to have ended;
it can only delete that guard generation, never replay rotation. An ended workflow alone is not
job-success evidence. Missing success, unavailable/expired execution metadata or a different live guard
requires separate reconciliation. Never age out or manually delete admission as routine cleanup.
Guard IAM is exact-object scoped; compliant code supplies the generation precondition, which IAM
itself does not enforce. First use requires separately approved receipt-read and Workflows metadata grants.

The native failed/cancelled Workflows system log pages the same service channel, even if no Cloud Run
execution was acknowledged. Cloud Run completion/freshness monitoring remains independent. Log-based
incident closure means silence, not recovery. Call logging is disabled and execution history is basic;
native system logs still contain status and error summaries. Inspect evidence privately.

### Provisioning and activation

The [pinned Scheduler provider](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/google/services/cloudscheduler/resource_cloud_scheduler_job.go)
creates enabled, then pauses. Execution-create permission is granted only afterward, so a fresh
Scheduler identity has no target authority during creation or a failed pause. Existing/inherited
grants need a separate revoke/reconcile procedure; dependency ordering cannot retract them.

`paused = true` is the creation default; `ignore_changes = [paused]` preserves subsequent operational
pause/resume. Foundation cannot use convergence to resume a held schedule. Before replacing any
existing direct-RunJob path, pause it, revoke its invoker grant and reconcile accepted executions
under the sole-writer boundary. Provisioning the dispatcher is not proof that the old path drained.

Workload-project prerequisites declare the APIs, Google agents and protected configuration permissions.
The selected foundation also needs its existing management bucket-IAM authority. Verify native source
deployment, stale-ETag rejection, effective IAM denials, guard contention, delayed delivery, uncertain dispatch and evidence
failure in the separately approved [activation drill](../../docs/runbooks/provision-service-projects.md#service-scheduling-activation).
There is no new activation flag, live provisioning or change to the current production schedule.

There is no custom dispatcher binary or hosted container. A provisioned schedule and executed workflow
incur [Scheduler](https://cloud.google.com/scheduler/pricing) and [Workflows](https://cloud.google.com/workflows/pricing)
charges, plus Cloud Run, storage and logging. The inactive configuration allocates none today.

## Completion monitoring

`google_monitoring_alert_policy.jobs` belongs to protected foundation in the selected service project.
It uses the existing Cloud Run `job/completed_execution_count` metric, with exact project, region and
job-name filters. No initializer, rollout probe, peer job, custom metric or polling runtime is included.
The version-1 runtime contract already publishes operations channels; this consumer requires at least
one and rejects channels outside the selected project.

| Native condition          | Meaning                                                                                                                    |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Unsuccessful completion   | A non-success result for an owned application job in a five-minute sum; no additional retest delay.                        |
| JSON Keys success count   | Fewer than one success in the rolling three-hour sum, sustained for one minute. Missing data is inactive.                  |
| JSON Keys success absence | No success samples for three hours after the series has been observed. This covers silence instead of zero-valued samples. |

The two gap conditions are deliberately separate: zero is data, absence is not. Treating missing data
as a threshold violation would use the retest duration, not the three-hour rolling window, and could
page between hourly executions. Google's metric is sampled every minute and can take another two
minutes to appear; these windows are not an exact wall-clock detection guarantee.

Before activation, seed a successful rotation and observe its metric **after installing or modifying
the policy**. Google's absence condition cannot establish health or detect a never-observed series.
It also excludes resources marked terminated/deleted; it is not a job-deletion or resource-inventory
alarm. Keep the protected job lifecycle and drift checks as separate safeguards.
Verify completion, gap detection and channel delivery in the separately approved pilot. Policy silence,
incident closure and scheduler HTTP success are not proof of application recovery. A completed job
also does not prove that a new key was needed or published.

The [workload project](../workload-project) grants protected foundation `roles/monitoring.alertPolicyEditor`;
it already owns channel administration. Release, application, scheduler and Cloud Deploy identities
receive no alert/channel-administration grant here. Keep current production alerts until the explicit one-writer
handoff. Deleting this policy removes monitoring, not jobs or evidence; the provider permits deletion
through the reviewed plan gate. Recovery omits this entire module.

Pausing rotation does not disable alerts. Long planned maintenance needs a separately authorized,
time-bounded snooze, not automatic policy suppression or unconditional schedule resume. Follow the
[service job response](../../docs/runbooks/respond-to-alerts.md#service-owned-job-pilot) before retrying.

There is no extra compute allocation. Native Google metric ingestion is non-chargeable; policy/query
costs follow [Observability pricing](https://cloud.google.com/products/observability/pricing). The inactive
module creates no billable resource today. References: [Cloud Run metric](https://docs.cloud.google.com/monitoring/api/metrics_gcp_p_z#run),
[absence prerequisites](https://docs.cloud.google.com/monitoring/alerts/metric-absence),
[alignment and missing data](https://docs.cloud.google.com/monitoring/alerts/concepts-indepth),
[policy resource](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/monitoring_alert_policy.html.markdown),
[Monitoring roles](https://docs.cloud.google.com/iam/docs/roles-permissions/monitoring).

Native mocked-provider plan tests cover both service scopes, scheduling, alert conditions and rejected runtime contracts. They
prove configuration only; live permissions and job execution still need a separately approved pilot.
References: [Cloud Run roles](https://docs.cloud.google.com/run/docs/reference/iam/roles),
[job IAM](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/cloud_run_v2_job_iam.html.markdown),
[operation resources](https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.operations/get),
[Scheduler resource](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/cloud_scheduler_job.html.markdown),
[service account resource](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/google_service_account.html.markdown),
[authenticated scheduling](https://docs.cloud.google.com/scheduler/docs/http-target-auth).
