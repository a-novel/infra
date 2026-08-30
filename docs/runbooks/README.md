# Production operations

These runbooks operate an existing production environment. For a new environment, follow the
one-time [production setup guide](../setup-production.md) instead.

## Operating rules

- Human commands run from the infrastructure repository root and must work from a fresh shell.
- Agents do not run `gcloud`, dispatch production workflows, or apply OpenTofu.
- Pull requests preview only. Cloud mutation starts from reviewed `master` behind a protected
  GitHub environment.
- The management bootstrap is the only local apply. Every later apply consumes one reviewed saved
  plan.
- Treat `PRODUCTION_RELEASES_ENABLED` as the release kill switch. Set it to `false` to freeze new
  release and rollback runs.
- Never paste secret payloads, plan/state values, credentials, authorization headers, or unfiltered
  provider diagnostics into GitHub or chat.
- Stop when a named invariant fails. Resume that command after correction; do not replay earlier
  successful mutations.

The human command map is [`ops/README.md`](../../ops/README.md). Architecture belongs in
[`docs/architecture.md`](../architecture.md), and Google-specific resource details belong in
[`docs/google-cloud.md`](../google-cloud.md).

## Start an operation

Create `.envrc` once with the root
[persistent operator configuration](../../README.md#configure-persistent-operator-inputs). Load it, then refresh the
repository and verify its gate:

```sh
. ./.envrc
./ops/verify-operator-env.sh --github
git switch master
git pull --ff-only
git status --short
./ops/verify-repository-gate.sh
```

Expected: the local IDs match every coordinate already published to GitHub, `master` is current,
status is empty, and the repository gate passes.

If resuming, inspect recent workflow state without changing anything:

```sh
gh run list --repo a-novel/infra --branch master --limit 20 \
  --json databaseId,workflowName,displayTitle,headSha,status,conclusion,createdAt,url
```

An active workflow must finish or be recovered before another production command is dispatched.

## Runbook index

| Need                                                   | Procedure                                                              |
| ------------------------------------------------------ | ---------------------------------------------------------------------- |
| Deploy or roll back an application version             | [Deploy and roll back production](./deploy-production.md)              |
| Scale, resize, inspect, or roll back the database host | [Operate the private PostgreSQL host](./operate-postgresql-host.md)    |
| Back up, restore, or prove a pre-change recovery gate  | [Back up and restore PostgreSQL](./backup-and-restore-postgresql.md)   |
| Add, rotate, disable, or destroy a payload version     | [Add or rotate a secret version](./secret-versions.md)                 |
| Replace or verify the hosted SMTP provider             | [Configure hosted SMTP](./configure-hosted-smtp.md)                    |
| Diagnose an alert or scheduled-check failure           | [Respond to production alerts](./respond-to-alerts.md)                 |
| Rebuild after the workload project is untrusted        | [Recover production into a disposable project](./disaster-recovery.md) |
| Recover an incorrect OpenTofu state object             | [Recover a prior state generation](./state-recovery.md)                |

Application rollback uses an immutable release receipt. Data recovery uses logical backups.
Clean-room recovery uses a new project. State recovery is a separate last-resort control.
