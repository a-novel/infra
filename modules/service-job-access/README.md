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

## Rotation schedule

JSON Keys alone declares these foundation-owned resources:

| Resource                                         | Contract                                                                                                             |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| `google_service_account.rotation[0]`             | Keyless `agora-json-keys-scheduler` identity in the service project; deletion blocked by `prevent_destroy`.          |
| `google_cloud_scheduler_job.rotation[0]`         | Fixed hourly `agora-json-keys-rotation`, initially paused, with provider deletion prevention and `prevent_destroy`.  |
| `google_cloud_run_v2_job_iam_member.rotation[0]` | Run Invoker on the exact `agora-json-keys-rotatekeys` job; removing the additive grant revokes this invocation path. |

The schedule sends an empty JSON body to the selected project's regional RunJob API with OAuth.
Its identity receives no job-update, migration, secret, runtime-attachment or token-minting grant.
The [workload project](../workload-project) declares the Google Scheduler service agent and its
documented role to mint that OAuth token. The job still runs as the application identity.
The [workload project](../workload-project#protected-provisioning-authority) declares protected Scheduler
configuration and job-IAM authority. This module grants `foundation_service_account` attachment on
the exact rotation identity before creating its schedule. Routine release receives none of these grants.

The [pinned provider](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/google/services/cloudscheduler/resource_cloud_scheduler_job.go)
creates an enabled schedule and then pauses it. The invoker grant depends on that completed operation:
a fresh identity has no target access during creation or a failed pause. Check inherited grants before
provisioning. This ordering does not prove the absence of a delayed, in-flight dispatch; first
activation still reconciles native attempts and executions. Replacement with an already-authorized identity requires an explicit revoke/reconcile
procedure; the dependency cannot retract existing authority. Deletion guards prevent routine replacement.

The request has zero configured transport retries. Scheduler still provides
[at-least-once delivery](https://docs.cloud.google.com/scheduler/docs/overview); rotation must tolerate
duplicate executions. RunJob returns an operation before the application finishes. A successful
schedule dispatch proves neither successful rotation nor exclusive execution. Keep completion monitoring
on Cloud Run executions. This scheduling pattern must not be used for migrations.

Foundation owns the schedule definition and IAM, not subsequent pause/resume decisions.
`paused = true` applies at creation; [native `ignore_changes`](https://opentofu.org/docs/language/resources/behavior/)
excludes only `paused` from later updates. The pinned provider also omits that field from ordinary
schedule PATCH requests. All other definition fields remain managed. Foundation will not repair an
unexpected resume: reconcile it through operational control, not another apply.

This ownership boundary grants no resume authority or activation input. Keep the schedule paused until
the [onboarding gates](../../docs/runbooks/provision-service-projects.md#service-scheduling-activation)
are met. Pausing dispatch does not stop accepted executions. Same-service exclusion must span pause,
dispatch reconciliation, execution drain, job changes, migrations, rollout and safe resume. An unknown
outcome stays paused for reconciliation; resume is never unconditional cleanup.

A provisioned schedule has [Scheduler charges](https://cloud.google.com/scheduler/pricing) even while
paused. Actual executions incur Cloud Run and logging costs. This inactive module adds none today.
Disposable recovery must omit this module; restoring data must not start production rotation.
The current production schedule and its IAM remain with the existing release/foundation owners.

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
