# Alerts

This runbook is about what to do when an alert fires or a scheduled check fails.

Google emails alerts to an operations channel: foundation's, or the service runtime's own, which
also receives that service's backup alerts. Budget alerts go to both the cost and the operations
channel.

Deploys and database rollouts post to the `a-novel-deployments` Discord channel when they start and
when they end. A deploy posts only when it changes a root, or when it fails. A failure pings the
`a-novel/infra` role and the failed service's role, whoever triggered the deploy. GitHub emails
failed `drift` runs to whoever last edited its schedule.

## Authentication health

`drift.yaml` calls Authentication's `/v2/healthcheck` every three hours. Each deploy calls it once
after applying the service roots, even when one of them failed. Both skip it while a planned
downtime runs. The job log prints the response:

| Shows `down`      | Look at                                                                                                   |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| `client:postgres` | [Database hosts](database.md#inspect-and-connect): is `agora-database.service` running? Is the disk full? |
| `client:smtp`     | [SMTP](secrets.md#smtp-google-workspace-relay): does the relay rule still admit the NAT address?          |
| `api:jsonKeys`    | The `agora-json-keys-grpc` logs in Cloud Run, then its database.                                          |

No response at all means Authentication itself is down. Read the logs of `agora-authentication-rest`
in the `a-novel-public-api-prod` project.

An SMTP warning with `category=timeout` in those logs means the connection never left: the
[egress allowlist](../architecture.md#network) or NAT dropped it, and neither logs a refusal.

If the checks stopped running, GitHub disabled the schedule after 60 days without repository
activity. Enable it again:

```bash
gh workflow enable drift.yaml --repo a-novel/infra
```

## Planned downtime past its end

The three-hourly check fails when a planned downtime is still in place after its announced `end`,
since its services still refuse work. [Clear it](downtime.md#clear-the-downtime) once the work is
done, or schedule it again with a later `end`.

## Authentication 5xx rate

More than 10% of requests failed for five minutes. If a deploy just happened,
[fix it forward](deployments.md#fix-a-bad-release). Otherwise, read the revision's logs and check
the dependencies [above](#authentication-health).

## GenAI sweep calls failing

At least three scheduled `/sweep` calls answered 5xx, other than 503, in ten minutes. Until the
sweep recovers, nobody checks a generation its owner stopped polling. That generation keeps its
owner's concurrency slot, and a finished result may expire at the provider. A planned downtime
answers 503, so it does not fire this alert.

1. Read the sweep's logs for the failing calls:

   ```bash
   gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="agora-genai-sweep" AND severity>=ERROR' \
     --project="$PROD" --freshness=1h --limit=50
   ```

2. Check GenAI's [database host](database.md#inspect-and-connect).
3. Check OpenAI's status page. The sweep fails when OpenAI refuses the key or is down. Connection
   timeouts instead mean the [egress allowlist](../architecture.md#network) or NAT dropped the
   calls, and neither logs a refusal.

## Application jobs and key rotation

A job execution failed, or the rotation job went three hours without a successful run. It runs
hourly and rotates the keys only once 24 hours have passed, so a single failure retries on its own.

```bash
gcloud logging read 'resource.type="cloud_run_job" AND severity>=ERROR' --project="$PROD" --freshness=6h --limit=50
```

A failed `migrations` job blocks its own deploy, as
[A deploy failed](deployments.md#a-deploy-failed) describes.

## Database capacity

| Alert                                     | Severity |
| ----------------------------------------- | -------- |
| CPU above 70% for ten minutes             | warning  |
| Memory or disk above 70% for ten minutes  | warning  |
| Memory or disk above 85% for five minutes | critical |

Each service with native backups also alerts its own channel when its database host's data disk is
above 85%, or reports no disk data for an hour. That alert finds the host by name, so it follows a
replaced VM.

[Connect to the host](database.md#inspect-and-connect) and look for the cause: long queries, the
connection count, or WAL that is not being archived. Then plan a
[capacity change](database.md#capacity). Never delete WAL files by hand.

## Backups

One of these happened:

- a backup failed;
- the Sunday full backup had not succeeded by 04:00 UTC;
- no backup succeeded in 24 hours 45 minutes;
- the hourly archive check has not succeeded in three hours.

Read the backup jobs' journal on the database host:

```bash
sudo journalctl -u 'agora-backup-*' --since=-1d
```

Common causes:

- the repository VM is stopped or unreachable (`agora-backup-repository.service`);
- a TLS certificate expires within 30 days, which calls for a
  [renewal](secrets.md#pgbackrest-tls-certificates);
- the database disk is full.

After fixing it, [take a backup by hand](database.md#back-up-now-and-verify). Keep WAL archiving
on.

## Budget

The [monthly budget](../costs.md) reached 50, 75, 90 or 100%, actual or forecast. In the billing
report, group by service. The usual causes are:

- Cloud Run instances that never go idle;
- backup storage growth, as [Costs](../costs.md) explains;
- rollout snapshots piling up.

Recovery drill projects sit outside the budget, so look for a forgotten one in the billing report
too.

## Drift

The cloud no longer matches `master`, and the job summary shows the plan. Either someone changed
something in the console, or a provider default moved. Undo the console change, or codify the new
value in a pull request. A recovery drill reports bootstrap as drifted while its backup reader is
enabled.
