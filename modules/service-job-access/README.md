# Service application job access

Protected foundation owns access to existing [application jobs](../service-jobs) and their schedules.
The module consumes the [service foundation's](../service-foundation) versioned `runtime` contract.
It derives fixed job names and the project-local `infra-release` principal; callers cannot supply
another principal or extend the job set. **Code only: no production root calls this module.**

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

Keep this module in protected foundation state. Transfer only job specifications to service release
state with saved private state, reconciliation and a reviewed one-writer procedure. Routine release
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
| `google_cloud_scheduler_job.rotation[0]`         | Fixed hourly `agora-json-keys-rotation`, hard-paused, with provider deletion prevention and `prevent_destroy`.       |
| `google_cloud_run_v2_job_iam_member.rotation[0]` | Run Invoker on the exact `agora-json-keys-rotatekeys` job; removing the additive grant revokes this invocation path. |

The schedule sends an empty JSON body to the selected project's regional RunJob API with OAuth.
Its identity receives no job-update, migration, secret, runtime-attachment or token-minting grant.
The [workload project](../workload-project) declares the Google Scheduler service agent and its
documented role to mint that OAuth token. The job still runs as the application identity.
Protected bootstrap needs Scheduler administration and `actAs` on the scheduling identity, in
addition to its existing job-IAM maintenance authority. Routine release receives none of these grants.

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

There is no activation input or ignored `paused` field. Keep the schedule paused until the
[onboarding gates](../../docs/runbooks/provision-service-projects.md#service-scheduling-activation)
are met. Pausing dispatch does not stop accepted Cloud Run executions. Same-service exclusion must
cover pause, dispatch reconciliation, execution drain, job updates, migrations, rollout and safe resume.
An unknown outcome stays paused for operator reconciliation; resuming must not be unconditional cleanup.

A provisioned schedule has [Scheduler charges](https://cloud.google.com/scheduler/pricing) even while
paused. Actual executions incur Cloud Run and logging costs. This inactive module adds none today.
Disposable recovery must omit this module; restoring data must not start production rotation.
The current production schedule and its IAM remain with the existing release/foundation owners.

Native mocked-provider plan tests cover both service scopes, scheduling and rejected runtime contracts. They
prove configuration only; live permissions and job execution still need a separately approved pilot.
References: [Cloud Run roles](https://docs.cloud.google.com/run/docs/reference/iam/roles),
[job IAM](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/cloud_run_v2_job_iam.html.markdown),
[operation resources](https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.operations/get),
[Scheduler resource](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/cloud_scheduler_job.html.markdown),
[service account resource](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/google_service_account.html.markdown),
[authenticated scheduling](https://docs.cloud.google.com/scheduler/docs/http-target-auth).
