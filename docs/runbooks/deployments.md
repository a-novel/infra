# Deployments

This runbook covers how merged changes reach production: what a deploy runs, how a service release
and its fix work, when a plan needs a label, and what to do when a deploy fails.
[Ops basics](../ops-basics.md#from-a-pull-request-to-production) explains the pipeline as a whole.

## What a deploy runs

Every merge to `master` starts `deploy.yaml`. It compares `master` with the last _successful_
deploy, and applies bootstrap and foundation only when their inputs changed since then:

- a root's own directory, or a local module it calls;
- the shared tooling, `.opentofu-version`, `.github/actions/` or `deploy.yaml`, which affects every
  root.

It applies every service root on every deploy. A service root also reads `DOWNTIME`, which no diff
shows: a downtime written while another deploy waited or ran must still reach the services, and an
unchanged service root applies nothing. The announcement lists only the roots that changed.

The service roots are the directories next to `foundation`, so deploy finds a new one by itself. Its
jobs cannot be generated, though: `lint-repository` fails until the new root has a `plan-<root>` job
in `main.yaml`, an apply job, a `changes` output and a `notify` entry in `deploy.yaml`, and an entry
in `drift.yaml`'s matrix. A root with a database host also joins the `rollout` matrix and the roll
action.

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
that waits for a downtime that has since started.

## Release a service

1. **The release opens its pull request.** Once a service's release workflow has published every
   image, it dispatches `pin-release.yaml`, which opens one pull request per service on
   `chore/deps/<repository>`, for example `chore(deps): update service-json-keys images to v2.10.0`.
   It moves every `tag@digest` pin of that service in `environments/production`, the database pin in
   foundation's `database_images` included, and the `FROM` lines of the `builds/` images built from
   it. A newer release of the same service replaces the open pull request's content.
2. **CI plans it.** In the service's plan check, expect:
   - the Cloud Run service and jobs on the new images;
   - when the migration image changed, its `terraform_data` replaced and a new
     `run_execution_token` on the migration job;
   - each new image verified: its release tag's own run built it, the release App published that
     tag as an immutable GitHub Release, and its version is not below the one deployed.
3. **It merges itself.** The Dependencies App opens it, so once its checks pass the auto-approve
   workflow approves it and queues it, as it does Renovate's. A `FROM` line counts as part of the
   pin when it takes a digest the same pull request pins in `environments/production`. When another release merges first and
   leaves it conflicting, the next push to `master` rebuilds it from `master`.
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

A release whose dispatch never ran, such as one cut before its repository dispatched releases,
is pinned by sending the event by hand:

```bash
gh api repos/a-novel/infra/dispatches -f event_type=release \
  -f 'client_payload[repository]=a-novel/service-json-keys' -f 'client_payload[version]=v2.10.1'
```

## Fix a bad release

Nothing rolls a release back: a pull request that lowers a pinned version fails its plan check.
Ship the fix as a new release of the service. When its `master` holds nothing unreleased but the
fix, a normal patch release ships it. Otherwise, ship a hotfix from the deployed line:

1. **Land the fix on `master`** through its pull request.
2. **Dispatch the service's `hotfix` workflow** with the deployed line and the fix's commit:

   ```bash
   gh workflow run hotfix.yaml --repo a-novel/service-json-keys \
     -f line=2.10 -f fix_refs=<commit> -f dry_run=false
   ```

   The first hotfix of a line creates `release/vX.Y` from the line's latest tag. That step waits for
   a `release` environment approval.

3. **The backport merges itself** when the fix applies unchanged: the Dependencies App opens it and
   the agent approves and queues it. A fix git had to fit to the line's code needs a review.
4. **Approve the cut.** The merged backport starts the cut, which waits for a `release` environment
   approval. The release App tags the minor's next free patch, and the tag's own run publishes the
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

Database migrations are never reverted. A data rollback is a [recovery](recovery.md), and a database
host change is undone as described in [Undo a rollout](database.md#undo-a-rollout).

## Deletions and weakened protections

A plan fails its check when it deletes, replaces or forgets a resource, or weakens
`deletion_protection`, `deletion_policy` or `force_destroy`. The check's error lists the addresses;
the job summary holds the full plan. Replacing an instance template or a `terraform_data` is
exempt: neither holds data.

If the change is intended:

1. **Add the `allow-resource-deletion` label.** The checks re-run immediately.
2. **Add it again after each push.** A push removes it, because it approved the plans of the
   previous commit.
3. **Merge with the label still on.** Before applying, the deploy checks that a pull request merged
   since the last successful deploy carried it, whether the deploy follows a merge or was run by
   hand.

## Database host changes

A plan that changes a database host needs the `allow-downtime` label and a planned downtime of that
service in progress. [Change a database host](database.md#change-a-database-host) covers the whole
procedure.

## A deploy failed

An apply that stops halfway keeps what it already applied. The state records it, and the next run
plans only the rest.

1. **Open the failed job.** The plan or apply output names the resource and the API error.
2. **Find the cause:**
   - **Transient API error or timeout:** select **Re-run failed jobs**. Every job plans again, so a
     re-run is safe. A re-run applies only while its commit is still `master`'s head; once `master`
     has moved on, it refuses, and a deploy run by hand applies the latest code instead.
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
   - **Health check failed after apply:** see [Alerts](alerts.md#authentication-health). If the
     release caused it, [fix it forward](#fix-a-bad-release).
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
