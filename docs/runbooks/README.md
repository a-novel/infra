# Production runbooks

This is the complete first-production-run order. Open only the current linked guide; each detailed
guide owns its commands, expected result, and recovery path.

## Operating rules

- Human commands run from the infrastructure repository root and must work from a fresh shell.
- Agents do not run `gcloud`, dispatch production workflows, or apply OpenTofu.
- Pull requests preview only. Cloud mutation starts from reviewed `master` behind a protected
  GitHub environment.
- The management bootstrap is the only local apply. Every later apply consumes one reviewed saved
  plan.
- Keep `PRODUCTION_RELEASES_ENABLED=false` until the launch guide explicitly enables it.
- Never paste secret payloads, plan/state values, credentials, authorization headers, or unfiltered
  provider diagnostics into GitHub or chat.
- Stop when a named invariant fails. Resume that command after correction; do not replay earlier
  successful mutations.

The human command map is [`ops/README.md`](../../ops/README.md). Architecture belongs in
[`docs/architecture.md`](../architecture.md), and Google-specific resource details belong in
[`docs/google-cloud.md`](../google-cloud.md).

## Start or resume

Refresh the repository and verify its gate:

```sh
git switch master
git pull --ff-only
git status --short
./ops/verify-repository-gate.sh
```

Expected: `master` is current, status is empty, the repository gate passes, and the release switch
is `false` before launch.

If resuming, inspect recent workflow state without changing anything:

```sh
gh run list --repo a-novel/infra --branch master --limit 20 \
  --json databaseId,workflowName,displayTitle,headSha,status,conclusion,createdAt,url
```

Resume after the last completed PASS row below. An active workflow must finish or be recovered before
another production command is dispatched.

## First production run

| Step | Procedure                                                                                                    | PASS condition                                                                                                                                                                               |
| ---: | ------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|    0 | Run the repository refresh and gate above.                                                                   | Clean current `master`; exact required checks, environments, labels, and disabled release switch.                                                                                            |
|    1 | [Bootstrap and verify the management plane](./bootstrap-management-plane.md).                                | Remote state, plan custody, four WIF providers, protected environments, recovery storage, secret containers, and audit controls pass; bootstrap authority is removed.                        |
|    2 | [Provision and verify the workload foundation](./provision-workload-foundation.md).                          | Both protected roots converge; one private workload project passes the stateless audit; temporary project, parent, billing, and audit access is removed.                                     |
|    3 | [Inspect the idle PostgreSQL host](./operate-postgresql-host.md#verify-foundation-state-after-apply).        | One private VM and preserved disk; no external IP and no running database container.                                                                                                         |
|    4 | [Configure hosted Plunk SMTP](./configure-hosted-smtp.md).                                                   | Organization-owned no-branding project, recovery access, spend cap, verified domain, tracking disabled, and private STARTTLS contract.                                                       |
|    5 | [Add the nine initial secret versions](./secret-versions.md).                                                | One selected enabled numeric version per secret; distinct database passwords; DSNs target only the private host; no payload appears in logs.                                                 |
|    6 | [Deploy JSON Keys and Authentication](./deploy-production.md).                                               | Exact reviewed release succeeds; initializer job is deleted; JSON Keys is private; Authentication is healthy; first backups/restores pass; hourly key rotation exists; receipt is immutable. |
|    7 | [Lock backup retention after recovery proof](./backup-and-restore-postgresql.md#lock-retention-after-proof). | Both backups are fresh, clean restores meet RTO, snapshots exist, and the seven-day retention policy is locked by reviewed code.                                                             |
|    8 | [Verify alert ownership and delivery](./respond-to-alerts.md).                                               | Eight policies and both verified email channels are active; scheduled GitHub health has a named owner and a recent success.                                                                  |
|    9 | [Run a clean-room recovery drill](./disaster-recovery.md).                                                   | Private replacement passes health and RPO/RTO; temporary access is removed; deletion-gated cleanup reaches `DELETE_REQUESTED`; cost is recorded privately.                                   |
|   10 | [Archive the legacy infrastructure repository](./archive-legacy-infrastructure.md).                          | Legacy credentials and Actions are disabled, open work is drained, and only `a-novel/agora-infra` is archived.                                                                               |

Do not advance on a partial PASS. A successful workflow is not rerun merely to recreate terminal
output; record its URL and continue.

## Routine and incident entry points

Do not restart the first-run sequence for routine work.

| Need                                                   | Procedure                                                              |
| ------------------------------------------------------ | ---------------------------------------------------------------------- |
| Deploy or roll back an application version             | [Deploy and roll back production](./deploy-production.md)              |
| Scale, resize, inspect, or roll back the database host | [Operate the private PostgreSQL host](./operate-postgresql-host.md)    |
| Back up, restore, or prove a pre-change recovery gate  | [Back up and restore PostgreSQL](./backup-and-restore-postgresql.md)   |
| Add, rotate, disable, or destroy a payload version     | [Add or rotate a secret version](./secret-versions.md)                 |
| Diagnose an alert or scheduled-check failure           | [Respond to production alerts](./respond-to-alerts.md)                 |
| Rebuild after the workload project is untrusted        | [Recover production into a disposable project](./disaster-recovery.md) |
| Recover an incorrect OpenTofu state object             | [Recover a prior state generation](./state-recovery.md)                |

Application rollback uses an immutable release receipt. Data recovery uses logical backups.
Clean-room recovery uses a new project. State recovery is a separate last-resort control.
