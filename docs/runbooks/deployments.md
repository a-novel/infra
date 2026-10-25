# Deployments

This runbook is about how merged changes reach production, and what to do when one does not.
[Ops basics](../ops-basics.md#from-a-pull-request-to-production) explains the pipeline as a whole.

## What a deploy runs

Every merge to `master` starts `deploy.yaml`. It compares `master` with the last _successful_
deploy, and applies bootstrap and foundation only when their inputs changed since then. A root's
inputs are:

- its own directory, and the local modules it calls;
- the tooling every root goes through: `.opentofu-version`, `.github/actions/tofu/` and
  `deploy.yaml`.

Markdown files never count, so a documentation change deploys nothing.

Every deploy applies every service root. A service root also reads `DOWNTIME`, which no diff shows,
and a downtime written while another deploy waited or ran must still reach the services. An
unchanged service root applies nothing, and the announcement lists only the roots that changed.

```text
changes ─► bootstrap ─► foundation ─► one job per service ─┬─► rollout (per service)
                                                           └─► health check
```

Each root's job plans, verifies and copies its images, then applies. The `rollout` job moves the
database hosts and backup repository VMs onto their applied configuration, as
[How the rollout works](database.md#how-the-rollout-works) details. The health check calls
Authentication's `/v2/healthcheck`, which also covers PostgreSQL, SMTP and JSON Keys. It runs
whenever the service roots applied, even when one of them failed, and skips while a planned downtime
runs.

Deploys run one at a time:

- A running deploy is never cancelled. A merge during it waits for it to finish.
- GitHub keeps one waiting run. A newer merge replaces it, and the replaced run never starts.
- Nothing is lost. The next run compares against the last successful deploy, so it covers the
  changes of any replaced or failed run.

A deploy run by hand applies every root. Only admins can start one:

```bash
gh workflow run deploy.yaml --repo a-novel/infra
```

Run one after a freeze, to undo drift the daily check reported, or to roll a database host change
that waits for a downtime that has since started.

## Release a service

1. **The release opens its pull request.** Once a service's release workflow has published every
   image, it dispatches `pin-release.yaml`. That workflow opens one pull request per service, on
   `chore/deps/<repository>`, titled like `chore(deps): update service-json-keys images to v2.10.0`.
   It moves every pin of the service's images: the `tag@digest` pins in `environments/production`,
   foundation's `database_images` included, and the `FROM` lines of the `builds/` images built from
   them. A newer release of the same service replaces the open pull request's content.
2. **CI plans it.** In the service's plan check, expect:
   - the Cloud Run service and jobs on the new images;
   - when the migration image changed, its `terraform_data` replaced and a new
     `run_execution_token` on the migration job;
   - each new image passing the [provenance check](../architecture.md#services).
3. **It merges itself.** The Dependencies App opens it, so the auto-approve workflow approves and
   queues it, as it does Renovate's updates. The queue merges it once its checks pass. A `FROM` line
   counts as part of the pin when it takes a digest the same pull request pins in
   `environments/production`. A blank line separates each service's pins in shared files, so
   releases of different services merge side by side. When a merge still leaves one conflicting,
   the next push to `master` rebuilds it from `master`.
4. **The deploy applies it:**
   1. it copies the images to the service's Artifact Registry repository;
   2. it applies, which runs the migration job and waits for it;
   3. Cloud Run moves traffic to the new revision once its startup probe passes;
   4. for JSON Keys and GenAI, it runs the smoke job;
   5. it checks production health.

Migrations must stay backward compatible. The previous revision keeps serving until the new one is
ready.

A release that changes the database image has a new digest, which changes the database hosts. Its
plan fails, so it waits for a planned downtime: merge it as a
[database host change](database.md#change-a-database-host). A release that only changes the service
keeps the database digest, because the database image builds reproducibly, and deploys right away.

When a release's dispatch never ran, send the event by hand:

```bash
REPOSITORY=a-novel/service-json-keys
VERSION=v2.10.1
gh api repos/a-novel/infra/dispatches -f event_type=release \
  -f "client_payload[repository]=$REPOSITORY" -f "client_payload[version]=$VERSION"
```

## Fix a bad release

Nothing rolls a release back. A pull request that lowers a pinned version fails its plan check, so
the fix ships as a new release of the service. When the service's `master` holds nothing unreleased
but the fix, a normal patch release ships it. Otherwise, ship a hotfix from the deployed line:

1. **Land the fix on `master`** through its pull request.
2. **Dispatch the service's `hotfix` workflow** with the deployed line and the fix's commit:

   ```bash
   REPOSITORY=a-novel/service-json-keys
   LINE=2.10
   FIX="<commit of the fix on master>"
   gh workflow run hotfix.yaml --repo "$REPOSITORY" \
     -f line="$LINE" -f fix_refs="$FIX" -f dry_run=false
   ```

   The first hotfix of a line creates `release/vX.Y` from the line's latest tag. That step waits for
   a `release` environment approval.

3. **The backport merges itself** when the fix applies unchanged. The Dependencies App opens it, and
   the Agent App approves and queues it. A backport git had to adapt to the line's code needs a
   review.
4. **Approve the cut.** The merged backport starts the cut, which waits for a `release` environment
   approval. The release App tags the line's next free patch, and the tag's own run publishes the
   images. `master`'s next patch release skips past that tag.
5. **The pin deploys** like any release.

The target is 30 minutes from dispatch to production, plus the approvals. Rerun the drill whenever
the hotfix path changes. The last one shipped JSON Keys v2.10.3 on 2026-10-18 in 22 minutes:

| Step                                 | Since dispatch |
| ------------------------------------ | -------------- |
| Release line created, after approval | 0:46           |
| Backport opened and approved         | 1:03           |
| Backport merged, after the line's CI | 6:17           |
| Cut tagged, after approval           | 7:58           |
| Images published                     | 12:22          |
| Pin pull request opened and approved | 12:34          |
| Pin merged, after the plans          | 17:39          |
| Production healthy                   | 22:26          |

Database migrations are never reverted. Damaged data goes back through [recovery](recovery.md), and
a faulty database host change is fixed forward, as
[Fix a bad host change](database.md#fix-a-bad-host-change) describes.

## Deletions and weakened protections

A plan fails its check when it deletes, replaces or forgets a resource, or weakens
`deletion_protection`, `deletion_policy` or `force_destroy`. The check's error lists the addresses,
and the job summary holds the full plan. Replacing an instance template or a `terraform_data` is
exempt, since neither holds data.

If the change is intended:

1. **Add the `allow-resource-deletion` label.** The checks re-run at once.

   ```bash
   PR="<pull request number>"
   gh pr edit "$PR" --repo a-novel/infra --add-label allow-resource-deletion
   ```

2. **Add it again after each push.** A push removes it, because it approved the plans of the
   previous commit.
3. **Merge with the label still on.** Before applying, the deploy checks that a pull request merged
   since the last successful deploy carried the label when it merged. A maintainer, an admin or the
   Agent App must have applied it last. The check holds whether the deploy follows a merge or was
   run by hand, and a label added after the merge counts for nothing.

## Database host changes

A plan that changes a database host needs the `allow-downtime` label and a planned downtime of that
service in progress. [Change a database host](database.md#change-a-database-host) covers the whole
procedure.

## A deploy failed

An apply that stops halfway keeps what it already applied. The state records it, and the next run
plans only the rest.

1. **Open the failed job.** The plan or apply output names the resource and the API error.

   ```bash
   gh run list --repo a-novel/infra --workflow deploy.yaml --limit 5
   RUN="<ID of the failed run>"
   gh run view "$RUN" --repo a-novel/infra --log-failed
   ```

2. **Find the cause:**
   - **Transient API error or timeout:** the plan retries Google's 503s on its own for two minutes,
     and authentication retries once. For an error that outlasts that, or one during the apply,
     re-run the failed jobs with `gh run rerun "$RUN" --repo a-novel/infra --failed`. Every job
     plans again, so a re-run is safe. A re-run applies only while its commit is still `master`'s
     head. Once `master` has moved on, it refuses, and a deploy run by hand applies the latest code
     instead.
   - **Failed migration or smoke check:** the old revision keeps serving. Read the job's logs, here
     for the JSON Keys migrations:

     ```bash
     JOB=agora-json-keys-migrations
     gcloud logging read "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"$JOB\"" \
       --project=a-novel-production-prod --freshness=1d --limit=50
     ```

     Fix the service and release it again, or fix the configuration in a new pull request. Every
     plan reads each job's last execution, and replaces the token source of one that failed, such
     as `terraform_data.migrations`, so the next deploy runs it again. A service that depends on a
     failed migration does not deploy until the migration passes.

   - **Configuration error:** fix it in a new pull request. Never fix resources in the console. The
     next plan reverts the change, and the drift check reports it.
   - **403 during apply:** pull-request plans run as the read-only identity, so they cannot catch a
     permission the deploy identity lacks. Grant it in the foundation root, or in bootstrap for the
     management project, and merge. The deploy applies the grant before it reaches the services.
   - **403 that names VPC Service Controls:** the service perimeter refused the call. Each
     project's policy audit log holds its violations, and in dry run the calls it would refuse:

     ```bash
     gcloud logging read 'log_id("cloudaudit.googleapis.com/policy")' \
       --project=a-novel-production-prod --freshness=1d
     ```

     Admit the call with a rule in foundation's `service-perimeter.tf`, in a new pull request.

   - **Rollout failed:** read the job log, then re-run it, or
     [roll the host by hand](database.md#roll-a-host-by-hand).
   - **Health check failed after apply:** see [Alerts](alerts.md#authentication-health). If the
     release caused it, [fix it forward](#fix-a-bad-release).

3. **"Error acquiring the state lock":** a cancelled run left its lock behind. Make sure no deploy
   is running, then [delete the lock](state.md#remove-a-stale-lock).

## Freeze production

Freeze deploys:

```bash
gh workflow disable deploy.yaml --repo a-novel/infra
```

Pull requests still pass CI and merge while frozen. `downtime.yaml` cannot start its deploy either,
so a downtime scheduled or cleared during a freeze reaches the services only after you resume.

Resume them, then run a deploy by hand to apply everything merged meanwhile:

```bash
gh workflow enable deploy.yaml --repo a-novel/infra
gh workflow run deploy.yaml --repo a-novel/infra
```

## Other cases

- **Fork pull requests** get no cloud credentials, so their plan checks fail. Push the branch to
  this repository to plan it.
- **Renaming or removing a job in `main.yaml`** changes the required checks. Merge the pull request
  with an admin bypass, then run `a-novel repo update` on `master`.
- **OpenTofu and provider upgrades** wait 7 days after release, or 6 hours for patches, before
  Renovate proposes them. Every pull-request plan runs those binaries with the read-only identity's
  access, so the wait leaves time for a compromised release to be found first.
