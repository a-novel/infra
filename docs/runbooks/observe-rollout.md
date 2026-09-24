# Observe one Cloud Deploy rollout

The observer is a code-only pilot. The observation-only path in `drift.yaml` is disabled until
separately approved activation; the delivery pipeline remains suspended. Submission, writer
serialization, receipt publication and workload cutover retain their separate approval gates.
The existing production release workflow is unchanged.

## Completion boundary

`infra observe-rollout` reads an exact release and rollout through Google's Cloud Deploy client.
The pilot uses the same ID for its delivery pipeline and target. Supply the full rollout resource
name with the **project number** from the reviewed submission record. It never selects the latest
release, submits a rollout, approves or advances one, retries a job, or changes traffic.

Rendering, target approval, and both the `canary-0` and `stable` deployment/verification jobs must
succeed. Skipped bootstrap phases and ignored verification cannot satisfy routine rollout success.
The private verifier owns revision/image/traffic and dependency health checks. This observer reads
their native completion state; it does not run another health probe.

| Observation                        | Operator action                                                                                                                  |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `succeeded`                        | Complete the separately tracked durable recovery receipt. This result alone does not complete a release.                         |
| `failed: render` or `canary-0/...` | Inspect the linked failed stage. Do not advance the rollout.                                                                     |
| `failed: stable/...`               | Treat as a failure after promotion. Inspect actual traffic and use the reviewed recovery procedure.                              |
| `action-required`                  | Review the indicated approval, advancement, cancellation or halted rollout in Cloud Deploy.                                      |
| `interrupted`                      | Cloud outcome is unknown. Re-observe the same identity after restoring access; no migration replay or new release is authorized. |

The observer returns zero only for `succeeded`. Required action stops observation promptly with
a failing status so CI can notify the operator. Its ten-minute default can be set up to thirty
minutes. A canceled or timed-out observer leaves the cloud operation running independently.

## Observation-only workflow

Before enabling this path, an administrator must approve the JSON Keys pilot's numeric pipeline
resource name against its converged foundation and submission coordinates. Store that native name
in the repository variable `GCP_JSON_KEYS_ROLLOUT_PARENT`:

```text
projects/PROJECT_NUMBER/locations/REGION/deliveryPipelines/agora-json-keys-grpc
```

This is an inspection allowlist, not a live-discovery result or deployment authorization. Verify
the existing plan identity can read this project's exact releases and rollouts, and cannot mutate
them, execute jobs or read secret payloads. The service-project module already declares Viewer
for that identity; [effective IAM](https://docs.cloud.google.com/iam/docs/roles-permissions/clouddeploy)
and federation still need a human check. Reuse `GCP_PLAN_WORKLOAD_IDENTITY_PROVIDER` and
`GCP_PLAN_SERVICE_ACCOUNT`; no new cloud grant is introduced here.

Only after those checks and separate approval, set `SERVICE_ROLLOUT_OBSERVATION_ENABLED=true`.
Leaving it unset makes a requested observation fail before authentication. The job builds reviewed
tooling, validates the selected scope, authenticates read-only and calls the existing observer.
It reads no state, secret versions, registry or peer resources.

From clean, current `master`, with the exact IDs retained by the submission operation:

```sh
go run ./cmd/infra drift observe-rollout json-keys "${CLOUD_DEPLOY_RELEASE_ID:?}" "${CLOUD_DEPLOY_ROLLOUT_ID:?}"
```

Use `production` only if that is the recorded rollout ID. This operation can run while a deployment
is active: its read-only concurrency group is separate from the unchanged infrastructure writer
group. It cannot satisfy a writer's exclusion or completion requirements. A ten-minute observation
runs within a twenty-minute job ceiling. The GitHub result and step summary report native failure,
required action or interrupted tracking; configure GitHub Actions notifications to receive run alerts.
Re-run this observation command for the same IDs after resolving the reported action. It never
submits, approves, advances, cancels, retries a cloud job or publishes a recovery receipt.

## Inline release tracking

Build reviewed tooling with `.github/actions/setup-infra` **before** cloud authentication. Use a
read-only identity able to get the exact Cloud Deploy release and rollout, without mutation, job
execution, approval, secret access or peer-project permissions. Verify effective grants before activation.

The repo-local action consumes that prebuilt command and existing credentials. It adds a console link,
phase verdict and recovery guidance to the GitHub step summary. Set the enclosing job timeout longer
than observation, preserve failure, and keep same-service serialization through receipt publication.

```yaml
- name: Observe submitted rollout
  uses: ./.github/actions/observe-rollout
  with:
    rollout: ${{ steps.submit.outputs.rollout_name }}
    timeout: 10m
```

`submit` is a future integration, not an existing action. It must persist the exact identity before
observation. Resume through an observation-only path; rerunning a job that also performs migrations
or release submission is not a safe observation retry. For an already authorized inspection, use the
same prebuilt command and identity:

```sh
infra observe-rollout --timeout=10m "${CLOUD_DEPLOY_ROLLOUT_NAME:?}"
```

A missing GitHub summary or a lost runner provides no cloud failure evidence. Native alert delivery,
receipt reconciliation and live interruption proof remain activation requirements in
[#189](https://github.com/a-novel/infra/issues/189).

State meanings follow the [Cloud Deploy rollout API](https://docs.cloud.google.com/deploy/docs/api/reference/rest/v1/projects.locations.deliveryPipelines.releases.rollouts).

## Native operations alerts

The inactive rollout module declares four Cloud Monitoring policies. After separately approved
provisioning, Cloud Deploy's platform logs trigger them without a GitHub runner or another watcher.
Each policy matches one project, region, and pipeline and uses the service project's existing
operations channels. The declaration currently sends no production notifications.

| Event                                         | Notification | Response                                                                                                  |
| --------------------------------------------- | ------------ | --------------------------------------------------------------------------------------------------------- |
| Rendering failed                              | Error        | Inspect the release's rendering error.                                                                    |
| Rollout failed, canceled, halted, or rejected | Error        | Inspect the exact rollout phase and actual serving traffic. Stable verification can fail after promotion. |
| Approval required                             | Warning      | Review the release and its prerequisites before approving it.                                             |
| Phase advancement required                    | Warning      | Review successful candidate verification before advancing to stable.                                      |

Use the release and rollout identifiers in the incident, not the most recent release in the console.
For an authorized inspection, re-observe that exact rollout using the command above. Alerts grant
no approval, retry, traffic change, or migration authority. Complete receipt reconciliation after a
verified rollout; neither an email nor the absence of one is deployment success evidence.

These are event notifications. Separate policies prevent routine approval requests from sharing a
notification throttle with rollout failures. Each policy allows at most one notification every five
minutes; repeated events can be suppressed. Release/rollout labels distinguish incidents, but native
[incident and notification limits](https://docs.cloud.google.com/logging/docs/alerting/log-based-incidents)
still apply. Pending work receives no periodic reminder without another matching event. Incidents
auto-close after seven days of silence, and only opening notifications are enabled. A closed incident
does not establish recovery or approval.

Before activating the pilot, the operator must verify that:

1. Logging and Monitoring are enabled, the foundation can manage log-based policies, and the selected
   operations channels are enabled and deliver to the intended recipients. A channel in the legacy
   workload project is not a channel in the new service project; provision the latter through its
   reviewed foundation configuration.
2. Project log routing retains both `clouddeploy.googleapis.com/release_render` and
   `clouddeploy.googleapis.com/rollout_update`. Excluded logs cannot trigger these policies. Filters
   match native event fields, not severity: a failed render can be logged at `INFO`.
3. An approved isolated drill produces each notification, including a deployment failure after its
   GitHub observer is stopped. Capture the exact release/rollout, phase, incident and receipt evidence.
   Confirm that peer-pipeline events do not alert this service. Local provider tests cannot prove delivery.

The policies adapt [Google's Cloud Deploy alert templates](https://github.com/GoogleCloudPlatform/monitoring-dashboard-samples/tree/master/alerts/google-cloud-deploy)
using the pinned provider. Their authored text and extracted labels contain identifiers and fixed
recovery guidance, without copying the platform log's free-form message. Cloud Monitoring owns incident
presentation and delivery. They cover native rollout events, not missing receipts or ambiguous migration
outcomes; those retain their separate completion/reconciliation gates.
