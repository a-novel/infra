# Deployments

This runbook covers how merged changes reach production: what a deploy runs, how a service release
and a rollback work, when a plan needs a label, and what to do when a deploy fails.
[Ops basics](../ops-basics.md#from-a-pull-request-to-production) explains the pipeline as a whole.

## What a deploy runs

Every merge to `master` starts `deploy.yaml`. It compares `master` with the last _successful_
deploy, and applies only the roots whose inputs changed since then:

- a root's own directory, or a local module it calls;
- the shared tooling, `.opentofu-version`, `.github/actions/` or `deploy.yaml`, which affects every
  root.

Markdown changes deploy nothing. A foundation change also deploys both services, which read its
outputs.

```text
changes ─► bootstrap ─► foundation ─► json-keys ──────┬─► rollout (per service)
                                      authentication ─┴─► health check
```

Each root's job plans, verifies and copies its images, then applies. The `rollout` job moves the
database hosts and backup repository VMs onto their applied configuration, as described in
[Change a database host](database.md#how-the-rollout-works). The health check calls Authentication's
`/v2/healthcheck`, which also covers PostgreSQL, SMTP and JSON Keys. It runs only when a service
root deployed, and skips while a planned downtime runs.

Deploys run one at a time:

- A running deploy is never cancelled. A merge during it waits for it to finish.
- GitHub keeps one waiting run. A newer merge replaces it, and the replaced run never starts.
- Nothing is lost: the next run compares against the last successful deploy, so it covers the
  changes of any replaced or failed run.

A deploy run by hand applies every root:

```bash
gh workflow run deploy.yaml --repo a-novel/infra
```

Use it after a freeze, to undo drift the daily check reported, or to roll a database host change
that waits for a downtime that has since started. A deploy run by hand checks the deletion label
only on the latest commit's pull request: a deletion merged earlier fails it, and needs that commit's
pull request labelled, or a new pull request carrying the label.

## Release a service

1. **Renovate opens one pull request per service release**, named after the service family, for
   example `service-json-keys images`. It updates each `tag@digest` image pin in that service's
   `terraform.tfvars`. Its database image is also pinned in foundation's `database_images`.
2. **CI plans it.** In the service's plan check, expect:
   - the Cloud Run service and jobs on the new images;
   - a new `run_execution_token` on the migration job, when the migration image changed;
   - each image's provenance verified against its service's release workflow.
3. **It merges itself.** Once its checks pass, the auto-approve workflow approves it and queues it;
   Renovate itself never merges production files.
4. **The deploy applies it:**
   1. it copies the images to the service's Artifact Registry repository;
   2. it applies, which runs the migration job and waits for it;
   3. Cloud Run moves traffic to the new revision once its startup probe passes;
   4. for JSON Keys, it runs the smoke job;
   5. it checks production health.

Migrations must stay backward compatible: the previous revision keeps serving until the new one is
ready.

A release that changes the database image has a new digest, which changes the database hosts. Its
plan fails, so it waits for a planned downtime: merge it as a
[database host change](database.md#change-a-database-host). A release that only changes the service
keeps the database digest, because the database image builds reproducibly, and deploys right away.

## Roll back

Revert the release pull request and merge the revert. Deploy redeploys the previous digests within
minutes.

Database migrations are not reverted. A data rollback is a [recovery](recovery.md), and a database
host change is undone as described in [Undo a rollout](database.md#undo-a-rollout).

## Deletions and weakened protections

A plan fails its check when it deletes, replaces or forgets a resource, or weakens
`deletion_protection`, `deletion_policy` or `force_destroy`. The check's error lists the addresses;
the job summary holds the full plan. Replacing an instance template is exempt: templates hold no
data.

If the change is intended:

1. **Add the `allow-resource-deletion` label.** The checks re-run immediately.
2. **Add it again after each push.** A push removes it, because it approved the plans of the
   previous commit.
3. **Merge with the label still on.** Before applying, the deploy checks that a pull request merged
   since the last successful deploy carried it. A deploy run by hand checks only the latest
   commit's pull request.

## Database host changes

A plan that changes a database host needs the `allow-downtime` label and a planned downtime of that
service in progress. [Change a database host](database.md#change-a-database-host) covers the whole
procedure.

## A deploy failed

An apply that stops halfway keeps what it already applied. The state records it, and the next run
plans only the rest.

1. **Open the failed job.** The plan or apply output names the resource and the API error.
2. **Find the cause:**
   - **Transient API error or timeout:** select **Re-run failed jobs**, on the latest deploy run
     only. Every job plans again, so that re-run is safe. An older run re-applies its own, older
     commit: once a newer deploy exists, run a deploy by hand instead.
   - **Configuration error:** fix it in a new pull request. Never fix resources in the console: the
     next plan reverts the change, and the drift check reports it.
   - **403 during apply:** pull-request plans run as the read-only identity, so they cannot catch a
     permission the deploy identity lacks. Grant it in the foundation root, or in bootstrap for the
     management project, and merge: the deploy applies the grant before it reaches the services.
   - **Migration failed**, when the job exits non-zero: the old revision keeps serving. Read the
     execution logs of `agora-<service>-migrations` in the Cloud Run console, fix the service, and
     release again.
   - **Rollout failed:** read the job log, then re-run it, or roll the host by hand
     ([Roll a host by hand](database.md#roll-a-host-by-hand)).
   - **Health check failed after apply:** see [Alerts](alerts.md#authentication-health), then roll
     back if the release caused it.
3. **"Error acquiring the state lock":** a cancelled run left its lock behind. Make sure no deploy
   is running, then delete the lock ([State](state.md#remove-a-stale-lock)).

## Freeze production

```bash
gh workflow disable deploy.yaml --repo a-novel/infra
gh workflow enable deploy.yaml --repo a-novel/infra
```

The first command freezes deploys; the second resumes them. Pull requests still pass CI and merge
while frozen. `downtime.yaml` cannot start its deploy either, so a downtime scheduled or cleared
during a freeze reaches the services only after you resume. After resuming, run a deploy by hand to
apply everything merged meanwhile.

## Other cases

- **Fork pull requests** get no cloud credentials, so their plan checks fail. Push the branch to
  this repository to plan it.
- **Renaming or removing a job in `main.yaml`** changes the required checks. Merge the pull request
  with an admin bypass, then run `a-novel repo update` on `master`.
- **OpenTofu and provider upgrades** wait 7 days after release, or 6 hours for patches, before
  Renovate proposes them. Every pull-request plan runs those binaries with the read-only identity's
  access, so the wait leaves time for a compromised release to be found first.
