# Alerts

This runbook is about what to do when an alert fires or a scheduled check fails.

Google emails alerts to an operations channel: foundation's, or the service runtime's own, which
also receives that service's backup alerts. Budget alerts go to both the cost and the operations
channel.

Deploys and database rollouts post to the `a-novel-deployments` Discord channel when they start and
when they end. A deploy posts only when it changes a root, or when it fails. A failure pings the
`a-novel/infra` role and the failed service's role, whoever triggered the deploy. GitHub emails
failed `drift` runs to whoever last edited its schedule.

## Grafana alerts

Grafana evaluates the cluster's alerts every minute. Its notification policy posts each one to
Discord through the hand-made `discord` contact point when it fires, every four hours while it
fires, and when it resolves. The rules sit in the stack's **Production** folder: one rule group per
service, plus `capacity`, `jobs`, `platform` and `usage`. Their thresholds are the Grafana root's `alerts` and
`thresholds` inputs, and the folder's **Services**, **Cluster** and **CloudNativePG** dashboards
draw the same metrics.

| Alert                            | Fires when                                                                                      |
| -------------------------------- | ----------------------------------------------------------------------------------------------- |
| `<service>: failing share`       | more than its `failure_rate` of its requests and job runs failed over 10 minutes, for 5 minutes |
| `<service>: slow requests`       | its requests' 95th percentile took longer than `p95_seconds` over 10 minutes, for 5 minutes     |
| `<service>: faults`              | a span failed in the last 10 minutes: one alert per span and error type                         |
| `<service>: new fault`           | the service raised an error type it had not raised in the week before                           |
| `Scheduled job failing`          | a CronJob's latest scheduled run has not succeeded for 15 minutes; a later success resolves it  |
| `Scheduled job missed`           | a CronJob is more than 10 minutes late for a run it never started                               |
| `Volume above 70%`, `85%`        | a database volume stays that full for 10 and 5 minutes                                          |
| `Node CPU above 80%`             | a node uses more than `node_cpu` of its CPU for 15 minutes                                      |
| `Node memory above 85%`          | a node uses more than `node_memory` of its memory for 10 minutes                                |
| `Replica lagging`                | a replica replays WAL more than `replica_lag` seconds behind its primary, for 5 minutes         |
| `Replica not streaming`          | a database's primary streams to no replica for 5 minutes                                        |
| `WAL archiving failing`          | a primary's latest WAL archive attempt failed, for 5 minutes                                    |
| `No room for a lost node's …`    | the pods' CPU or memory requests exceed every node but the largest, for 15 minutes              |
| `Cluster above its baseline`     | the cluster has run more nodes than foundation's `cluster.min_nodes` for 2 hours                |
| `Autoscaler at its maximum`      | the cluster has run as many nodes as foundation's `cluster.max_nodes` for 30 minutes            |
| `Collector silent`               | no scrape reached Grafana for 10 minutes                                                        |
| `Container CPU above 80% …`      | a container uses more than `container_cpu` of the CPU it requests for 15 minutes                |
| `Container memory above 85% …`   | a container uses more than `container_memory` of its memory limit for 10 minutes                |
| `Container killed for memory`    | a container restarted after running out of memory                                               |
| `Pod waiting to start`           | a pod has waited 10 minutes for a node or its image                                             |
| `Workload autoscaler at its max` | a workload's autoscaler has run its most replicas for 15 minutes                                |
| `<database>: connections above…` | a database holds more than `database_connections` of its `max_connections` for 10 minutes       |
| `Usage: … above 80% of the plan` | a Grafana Cloud allowance reached `usage` of what the Pro plan includes this month              |
| `Usage: overage`                 | this month's usage costs anything beyond the plan                                               |

- **A fault** is filed by hand, from its Discord post, as an issue in the service's repository. Its
  span name and error type locate it, and a TraceQL search such as
  `{ resource.service.name = "service-json-keys" && span.error.type = "<error type>" }` in Explore
  shows its traces.
- **A failed or missed CronJob:** read its Jobs and their logs with `kubectl`, as
  [Ops basics](../ops-basics.md) shows. A failed run is not retried, and the next one takes over.
- **A full volume, a lagging replica or failing archiving:** read the database's state on the
  CloudNativePG dashboard first. Barman's archive errors appear in the instance's logs. Never
  delete WAL by hand.
- **The cluster above its baseline:** the autoscaler absorbs spikes and transient load; capacity that
  stays is a decision. Raise foundation's `cluster.min_nodes`, or lower the load, in a pull request,
  or let it fall back once the load passes.
- **No room for a lost node, or the autoscaler at its maximum:** raise foundation's
  `cluster.max_nodes`, or lower a workload's requests, in a pull request. Mind the SSD quota the
  nodes' disks share with the volumes.
- **A container near its CPU request or memory limit, or killed for memory:** raise its request or
  limit in a pull request, the cluster root's `databases` for a database, before it saturates. No
  container has a CPU limit, so a busy one slows its neighbours rather than throttling; memory past
  the limit kills the container.
- **A pod waiting to start, or a workload's autoscaler at its maximum:** the cluster or the workload
  is out of room. Raise the workload's `replicas.max`, or foundation's `cluster.max_nodes` with its
  CPU quota, in a pull request.
- **A database near its connection limit:** raise its `max_connections` in the cluster root's
  `databases`, and its memory with it, in a pull request.
- **The collector silent:** Alloy's pod in the `alloy` namespace, its
  [push token](secrets.md#alloy-push-token) or its egress to Grafana's gateway stopped.

A test notification from **Alerting → Contact points** proves the `discord` contact point's
webhook. A firing rule proves the policy too, such as `Autoscaler at its maximum` while the pool
runs its largest size.

## Authentication health

`drift.yaml` calls Authentication's `/v2/healthcheck` every three hours, then Studio's public
`/healthcheck`, which asks Authentication again as Studio. Each deploy calls both once after
applying the service roots, even when one of them failed. Both skip them while a planned downtime
runs. The job log prints each response:

| Shows `down`      | Look at                                                                                                   |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| `client:postgres` | [Database hosts](database.md#inspect-and-connect): is `agora-database.service` running? Is the disk full? |
| `client:smtp`     | [SMTP](secrets.md#smtp-google-workspace-relay): does the relay rule still admit the NAT address?          |
| `api:jsonKeys`    | The `agora-json-keys-grpc` logs in Cloud Run, then its database.                                          |

No response at all means Authentication itself is down. Read the logs of `agora-authentication-rest`
in the `a-novel-public-api-prod` project. When only Studio's check fails, Studio is down or
Authentication refuses it: read the logs of `agora-studio-web` in the `a-novel-public-prod` project.

An SMTP warning with `category=timeout` in those logs means the connection never left: the
[egress allowlist](../architecture.md#network) or NAT dropped it, and neither logs a refusal. When
the address it dialed lies outside `environments/production/foundation/google-service-ranges.json`,
dispatch `refresh-google-ranges.yaml`, whose pull request proposes Google's current list.

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
     --project=a-novel-production-prod --freshness=1h --limit=50
   ```

2. Check GenAI's [database host](database.md#inspect-and-connect).
3. Check OpenAI's status page. The sweep fails when OpenAI refuses the key or is down. Connection
   timeouts instead mean the [egress allowlist](../architecture.md#network) or NAT dropped the
   calls, and neither logs a refusal.

## GenAI purge falling behind

An expired generation waited more than 30 minutes for the retention purge, or GenAI's database host
logged no wait for 30 minutes. Every five minutes, the host's `a-novel-database-probe.timer` logs
how long the oldest expired generation has waited. pg_cron runs the purge every 10 seconds, oldest
first, at most 1,000 rows and 64 MiB a call, so the wait stays near zero. Past 30 minutes, either
the purge stopped, or more than 30 minutes of its fastest pace, about 11 GiB, waits ahead. Expired
content then fills the data disk.

[Connect to GenAI's host](database.md#inspect-and-connect), then read the schedules, the backlog and
the last runs:

```bash
sudo docker exec --user postgres agora-postgres-genai psql -U agora_genai -d agora_genai \
  -c 'SELECT jobname, schedule, active FROM cron.job;' \
  -c 'SELECT count(*) FROM generations WHERE expires_at < now();' \
  -c 'SELECT status, return_message, start_time FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;'
```

- **`service-genai-purge-settled` is missing:** the migrations job ran against another database, and
  skipped the schedule without an error. Fix its target, then run it again.
- **The runs fail:** their `return_message` says why.
- **The runs succeed and the backlog still grows:** settled content arrives faster than the purge
  deletes it. The disk alerts give the time left. Raising the purge's batch is a service-genai
  change.
- **No wait was logged:** check `sudo systemctl status a-novel-database-probe.timer` and
  `sudo journalctl -u a-novel-database-probe.service --since=-1h`. A stopped PostgreSQL also fires
  the sweep alert.

## Application jobs and key rotation

A job execution failed, or the rotation job went three hours without a successful run. It runs
hourly and rotates the keys only once 24 hours have passed, so a single failure retries on its own.

```bash
gcloud logging read 'resource.type="cloud_run_job" AND severity>=ERROR' \
  --project=a-novel-production-prod --freshness=6h --limit=50
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
enabled. A plan that replaces a job's or service's token source, which the job's warning names,
means its last execution or rollout failed: follow
[A deploy failed](deployments.md#a-deploy-failed).
