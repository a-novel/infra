# Observe one Cloud Deploy rollout

The observer is a code-only pilot. No production workflow calls it, and the delivery pipeline
remains suspended. IAM, submission, serialization, receipt publication and live activation need
their separate reviewed changes. The existing production release workflow is unchanged.

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

## Future workflow caller

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

A missing GitHub summary or a lost runner provides no cloud failure evidence. Independent native
alerts through the operations channel, receipt reconciliation and live interruption proof remain
activation requirements in [#189](https://github.com/a-novel/infra/issues/189).

State meanings follow the [Cloud Deploy rollout API](https://docs.cloud.google.com/deploy/docs/api/reference/rest/v1/projects.locations.deliveryPipelines.releases.rollouts).
