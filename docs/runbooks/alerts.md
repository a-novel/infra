# Alerts

Google sends alert emails to the operations channel and budget emails to the cost channel. GitHub
emails failed `drift` and `deploy` runs to the person who last changed the workflow.

## Authentication health

`drift.yaml` checks every three hours, and every deploy checks once. The job log prints the health
response:

| Shows `down`      | Look at                                                                                                         |
| ----------------- | --------------------------------------------------------------------------------------------------------------- |
| `client:postgres` | [Database hosts](database.md#inspect-and-connect): is `agora-database.service` running? Is the disk full?       |
| `client:smtp`     | [SMTP](secrets.md#smtp-google-workspace-relay): was the app password revoked? Is the relay rule still in place? |
| `api:jsonKeys`    | The `agora-json-keys-grpc` logs in Cloud Run; also check its database.                                          |

No response at all means Authentication itself is down. Read the logs of `agora-authentication-rest`
in the `a-novel-public-api-prod` project.

If the checks stopped running, GitHub disabled the schedule after 60 days without repository
activity. Run `gh workflow enable drift.yaml --repo a-novel/infra`.

## Authentication 5xx rate

More than 10% of requests failed for five minutes. If a deploy just happened,
[roll it back](deployments.md#roll-back). Otherwise read the revision's logs and check the
dependencies above.

## Application jobs and key rotation

A job execution failed, or JSON Keys went three hours without a successful rotation. Rotation runs
hourly and the job enforces 24 hours between rotations, so a single failure retries on its own.

```bash
gcloud logging read 'resource.type="cloud_run_job" AND severity>=ERROR' --project="$PROD" --freshness=6h --limit=50
```

A failed `migrations` job blocks its own deploy; see [failed deploys](deployments.md#a-deploy-failed).

## Database capacity

CPU or memory has been above 70%, or the disk above 85%. Connect to the host
([Database hosts](database.md)) and look for the cause: long queries, connection count, or WAL
that is not being archived. Then plan a [capacity change](database.md#capacity). Never delete WAL
files by hand.

## Backups

These alerts mean a backup failed, a backup was missed, or the hourly check stopped succeeding.

```bash
# on the database host
sudo journalctl -u 'agora-backup-*' --since=-1d
```

Common causes:

- the repository VM is stopped or unreachable (`agora-backup-repository.service`);
- a TLS certificate expires within 30 days; see [renewal](secrets.md#pgbackrest-tls-certificates);
- the database disk is full.

After fixing it, [take a backup by hand](database.md#back-up-now-and-verify). Do not turn off WAL
archiving and do not delete WAL.

## Budget

The monthly budget (60 units) reached 50, 75, 90 or 100%, actual or forecast. In the billing report,
group by service. Usual suspects:

- Cloud Run instances that never go idle;
- a forgotten recovery project;
- backup storage growth.

See [costs](../costs.md).

## Drift

The cloud no longer matches `master`; the job summary shows the plan. Either someone changed
something in the console, or a provider default moved. Revert the console change, or codify the new
value in a pull request.
