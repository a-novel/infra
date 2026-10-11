# Alerts

This runbook covers what to do when an alert fires or a scheduled check fails.

Google emails alerts to the operations channels: foundation's, and one per service runtime, which
also receives that service's backup alerts. Budget alerts go to both the cost and operations
channels. GitHub emails a failed `deploy` run to whoever triggered it, and failed `drift` runs to
whoever last edited its schedule. A run a bot triggered, such as the deploy of a Renovate release,
emails nobody: check the deploy runs after bot merges.

## Authentication health

`drift.yaml` calls Authentication's `/v2/healthcheck` every three hours, and each deploy that changed
a service calls it once. Both skip it while a planned downtime runs. The job log prints the response:

| Shows `down`      | Look at                                                                                                         |
| ----------------- | --------------------------------------------------------------------------------------------------------------- |
| `client:postgres` | [Database hosts](database.md#inspect-and-connect): is `agora-database.service` running? Is the disk full?       |
| `client:smtp`     | [SMTP](secrets.md#smtp-google-workspace-relay): was the app password revoked? Is the relay rule still in place? |
| `api:jsonKeys`    | The `agora-json-keys-grpc` logs in Cloud Run; also check its database.                                          |

No response at all means Authentication itself is down. Read the logs of `agora-authentication-rest`
in the `a-novel-public-api-prod` project.

If the checks stopped running, GitHub disabled the schedule after 60 days without repository
activity. Run `gh workflow enable drift.yaml --repo a-novel/infra`.

## Planned downtime past its end

The three-hourly check fails when a planned downtime is still in place after its announced `end`:
its services still refuse work. [Clear it](downtime.md#clear-the-downtime) once the work is done, or
schedule it again with a later `end`.

## Authentication 5xx rate

More than 10% of requests failed for five minutes. If a deploy just happened,
[roll it back](deployments.md#roll-back). Otherwise read the revision's logs and check the
dependencies above.

## Application jobs and key rotation

A job execution failed, or the rotation job went three hours without a successful run. It runs
hourly and rotates the keys only once 24 hours have passed, so a single failure retries on its own.

```bash
gcloud logging read 'resource.type="cloud_run_job" AND severity>=ERROR' --project="$PROD" --freshness=6h --limit=50
```

A failed `migrations` job blocks its own deploy; see [A deploy failed](deployments.md#a-deploy-failed).

## Database capacity

| Alert                                     | Severity |
| ----------------------------------------- | -------- |
| CPU above 70% for ten minutes             | warning  |
| Memory or disk above 70% for ten minutes  | warning  |
| Memory or disk above 85% for five minutes | critical |

Each service also alerts its own channel when its database host's disk is above 85%, or reports no
disk data for an hour. That alert finds the host by name, so it follows a replaced VM.

[Connect to the host](database.md#inspect-and-connect) and look for the cause: long queries, the
connection count, or WAL that is not being archived. Then plan a [capacity change](database.md#capacity).
Never delete WAL files by hand.

## Backups

One of these happened:

- a backup failed;
- the Sunday full backup had not succeeded by 04:00 UTC;
- no backup succeeded in 24 hours 45 minutes;
- the hourly archive check has not succeeded in three hours.

These alerts find the database host by its VM's ID. After a rollout that replaced the VM, they watch
the old one until the service deploys again, at the latest when its downtime is cleared, and can fire
falsely in between.

```bash
# on the database host
sudo journalctl -u 'agora-backup-*' --since=-1d
```

Common causes:

- the repository VM is stopped or unreachable (`agora-backup-repository.service`);
- a TLS certificate expires within 30 days; see [renewal](secrets.md#pgbackrest-tls-certificates);
- the database disk is full.

After fixing it, [take a backup by hand](database.md#back-up-now-and-verify). Keep WAL archiving
on, and never delete WAL.

## Budget

The monthly budget (60 units, the four production projects) reached 50, 75, 90 or 100%, actual or
forecast. In the billing report, group by service. Usual suspects:

- Cloud Run instances that never go idle;
- backup storage growth (see [costs](../costs.md));
- rollout snapshots piling up.

Recovery drill projects sit outside the budget: look for a forgotten one in the billing report too.

## Drift

The cloud no longer matches `master`; the job summary shows the plan. Either someone changed
something in the console, or a provider default moved. Undo the console change, or codify the new
value in a pull request. A recovery drill reports bootstrap as drifted while its backup reader is
enabled.
