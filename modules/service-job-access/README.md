# Service application job access

Protected foundation owns these additive IAM grants for existing [application jobs](../service-jobs).
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
Cloud Deploy retry hooks; scheduled rotation needs its own reviewed invocation and pause/drain policy.

Native mocked-provider plan tests cover both service scopes and rejected runtime contracts. They
prove configuration only; live permissions and job execution still need a separately approved pilot.
References: [Cloud Run roles](https://docs.cloud.google.com/run/docs/reference/iam/roles),
[job IAM](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/cloud_run_v2_job_iam.html.markdown),
[operation resources](https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.operations/get).
