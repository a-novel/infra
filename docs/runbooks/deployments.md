# Deployments

## Release a service

1. Renovate opens one pull request per service family when a new tag is published, for example
   `service-json-keys images`. It updates each `tag@digest` in that service's `terraform.tfvars`.
2. Read the service's plan check:
   - the Cloud Run service and jobs change images;
   - the migration job gets a new `run_execution_token`;
   - provenance verification passed.
3. Merge. Deploy runs only that service's root:
   1. it copies the images;
   2. it applies, which runs the migration and waits for it;
   3. it moves traffic to the new revision once its startup probe passes;
   4. for JSON Keys, it runs the smoke job;
   5. it checks production health.

Migrations must stay backward compatible, because the previous revision keeps serving until the new
one is ready.

## What a deploy runs

A deploy compares `master` with the last successful deploy. It runs only the roots whose files
changed: the root's directory, the modules it calls, or the shared tooling (`.opentofu-version`,
`.github/actions/`, `deploy.yaml`). Markdown changes deploy nothing. A foundation change also
re-plans both services, which read its outputs.

Bootstrap runs first, then foundation, then the services in parallel, then the health check.
Services never wait for each other: when one service needs a change from another, merge that change
first, in its own pull request.

Running `deploy` by hand applies every root:

```bash
gh workflow run deploy.yaml --repo a-novel/infra
```

Use it after a freeze, or to undo drift that the daily check reported.

## Merges during a deploy

- A running deploy is never cancelled. A merge during it waits for it to finish.
- GitHub keeps one waiting run. A newer merge replaces it, and the replaced run never starts.
- Nothing is lost. The next run compares against the last _successful_ deploy, so it covers the
  replaced or failed runs' changes and their deletion labels.

## Roll back

Revert the release pull request and merge the revert. Deploy redeploys the previous digests within
minutes.

Database migrations are **not** reverted. A data rollback is a [recovery](recovery.md).

## Deletions and weakened protections

A plan that deletes, replaces or forgets a resource, or relaxes `deletion_protection`,
`deletion_policy` or `force_destroy`, fails its check. The job summary lists the addresses.

If the change is intended:

1. Add the `allow-resource-deletion` label. The checks re-run immediately.
2. Merge with the label still on. Before it applies, deploy checks again that a pull request in
   the deploy carried the label.

## A deploy failed

An apply that stops halfway keeps what it already applied. The state records it, and the next run
plans only the rest.

1. Open the failed job. The plan or apply output names the resource and the API error.
2. Find the cause:
   - **Transient API error or timeout:** select **Re-run failed jobs**. Every job re-plans, so a
     re-run is safe.
   - **Configuration error:** fix it in a new pull request. Never edit resources in the console:
     drift reverts it, and the next plan fights it.
   - **403 during apply:** the pull-request plan ran as the read-only identity, so it cannot catch
     a permission the writer lacks. Grant it in the foundation root (bootstrap for the management
     project), and merge; deploy applies the grant before it reaches the service roots.
   - **Migration failed** (the job exits non-zero): the old revision keeps serving. Read the
     execution logs in the Cloud Run console (`agora-<service>-migrations`), fix the service, and
     release again.
   - **Health check failed after apply:** see [Alerts](alerts.md#authentication-health), then roll
     back if the release caused it.
3. **"Error acquiring the state lock":** a cancelled run left its lock behind. Make sure no deploy
   is running, then delete the lock (see [State](state.md#remove-a-stale-lock)).

## Freeze production

```bash
gh workflow disable deploy.yaml --repo a-novel/infra
gh workflow enable deploy.yaml --repo a-novel/infra
```

The first command freezes deploys; the second resumes them. Merges still pass CI while frozen.
After re-enabling, run `deploy` by hand to apply them.

## Other cases

- **Fork pull requests** get no cloud credentials, so their plan checks fail. Push the branch to
  this repository to plan it.
- **Changing a job name in `main.yaml`** changes the required checks. Merge the pull request with an
  admin bypass, then run `a-novel repo update` on `master`.
- **OpenTofu and provider upgrades** wait 7 days after release (6 hours for patches) before Renovate
  proposes them, because pull-request plans run the new binaries with the read-only identity.
