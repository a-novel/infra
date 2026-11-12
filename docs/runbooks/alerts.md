# Alerts

This runbook is about what to do when an alert fires or a scheduled check fails.

Grafana posts every alert to Fluxer, as [Grafana alerts](#grafana-alerts) describes. Google
emails the budget alerts to both the cost and the operations addresses.

Deploys post to the `a-novel-deployments` Fluxer channel when they start and when they end. A
deploy posts only when it changes a root, or when it fails. A failure pings the `a-novel/infra` role
and the failed service's role, whoever triggered the deploy. GitHub emails failed `drift` runs to
whoever last edited its schedule.

## Grafana alerts

Grafana evaluates the cluster's alerts every minute. Its notification policy posts each one to
Fluxer through the hand-made `discord` contact point when it fires, every four hours while it
fires, and when it resolves. The rules sit in the stack's **Production** folder: one rule group per
service, plus `capacity`, `data`, `jobs`, `platform`, `rate-limits` and `usage`. Their thresholds
are the Grafana root's `alerts` and `thresholds` inputs.

The folder's dashboards make a daily journey, linked in each one's header, and Grafana opens on its
first step:

1. **Errors:** what needs action now, and the alerts that fire.
2. **Health:** nodes, pods, resources against their requests, limits and budgets, traffic, databases.
3. **Performance:** latency against the period before, the slowest operations and steps.
4. **Services:** one tab per service with its own numbers, such as tokens consumed or mails sent.

A new service appears on the first three by itself. Its thresholds and its Services tab come with
it, as [Contributing](../../CONTRIBUTING.md#rules) describes.

Core sets that home dashboard by hand, under **Administration → General → Default preferences**:
reading it needs a role that also writes the organization, which the plan token must not hold.
**CloudNativePG** details each database, from Health. Each alert's post links the panel that draws
what it watches.

Alloy gives each request, job run and email send an outcome, which the dashboards and alerts read:

| Outcome     | Means                               | Codes                                                                                                                                                              |
| ----------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `fault`     | our own failure: fix it             | any other failure: HTTP 5xx, gRPC `INTERNAL`, `UNKNOWN`, `DATA_LOSS`, `UNIMPLEMENTED`, a panic, a failed job or email send                                         |
| `transient` | a dependency or timeout: watch it   | HTTP 429, 502, 503, 504; gRPC `UNAVAILABLE`, `DEADLINE_EXCEEDED`, `RESOURCE_EXHAUSTED`, `ABORTED`; PostgreSQL `57P01`, `57P02`, `57P03` (a database handover)      |
| `expected`  | the caller's own mistake: no action | other HTTP 4xx; gRPC `CANCELLED`, `INVALID_ARGUMENT`, `NOT_FOUND`, `ALREADY_EXISTS`, `PERMISSION_DENIED`, `UNAUTHENTICATED`, `FAILED_PRECONDITION`, `OUT_OF_RANGE` |
| `ok`        | success                             |                                                                                                                                                                    |

| Alert                                | Fires when                                                                                        |
| ------------------------------------ | ------------------------------------------------------------------------------------------------- |
| `<service>: failing share`           | more than its `failure_rate` of its calls were faults or transient over 10 minutes, for 5 minutes |
| `<service>: slow requests`           | its requests' 95th percentile took longer than `p95_seconds` over 10 minutes, for 5 minutes       |
| `<service>: faults`                  | a fault in the last 10 minutes: one alert per span and error type                                 |
| `<service>: new fault`               | a fault of an error type the service had not faulted with in the week before                      |
| `Scheduled job failing`              | a CronJob's latest scheduled run has not succeeded for 15 minutes; a later success resolves it    |
| `Scheduled job missed`               | a CronJob is more than 10 minutes late for a run it never started                                 |
| `Volume above 70%`, `85%`            | a database volume stays that full for 10 and 5 minutes                                            |
| `Node CPU above 80%`                 | a node uses more than `node_cpu` of its CPU for 15 minutes                                        |
| `Node memory above 85%`              | a node uses more than `node_memory` of its memory for 10 minutes                                  |
| `Replica lagging`                    | a replica replays WAL more than `replica_lag` seconds behind its primary, for 5 minutes           |
| `Replica not streaming`              | a database's primary streams to no replica for 5 minutes                                          |
| `WAL archiving failing`              | a primary's latest WAL archive attempt failed, for 5 minutes                                      |
| `Base backup stale`                  | a database's last base backup is more than 26 hours old, for an hour                              |
| `No room for a lost node's …`        | the pods' CPU or memory requests exceed every node but the largest, for 15 minutes                |
| `Cluster above its baseline`         | the cluster has run more nodes than foundation's `cluster.min_nodes` for 2 hours                  |
| `Autoscaler at its maximum`          | the cluster has run as many nodes as foundation's `cluster.max_nodes` for 30 minutes              |
| `Collector silent`                   | no scrape reached Grafana for 10 minutes                                                          |
| `Gateway refused`                    | GKE warned about a platform's Gateway, route or policy in the last 15 minutes                     |
| `Container CPU above 80% …`          | a container uses more than `container_cpu` of the CPU it requests for 15 minutes                  |
| `Container memory above 85% …`       | a container uses more than `container_memory` of its memory limit for 10 minutes                  |
| `Container killed for memory`        | a container restarted after running out of memory                                                 |
| `Pod waiting to start`               | a pod has waited 10 minutes for a node or its image                                               |
| `Service above 80% of its budget`    | a service's pods request more than `service_budget` of its namespace's quota for 10 minutes       |
| `Workload autoscaler at its max`     | a workload's autoscaler has run its most replicas for 15 minutes                                  |
| `<database>: connections above…`     | a database holds more than `database_connections` of its `max_connections` for 10 minutes         |
| `Usage: … above 80% of the plan`     | a Grafana Cloud allowance stayed past `usage` of the Pro plan this month, for 30 minutes          |
| `Usage: overage`                     | this month's usage costs anything beyond the plan                                                 |
| `Signing keys running out`           | a key usage's newest key signs for less than 3 days more, for 15 minutes                          |
| `GenAI keeps content past retention` | a settled generation stays stored 30 minutes past its retention, for 5 minutes                    |
| `Certificate expiring`               | a certificate cert-manager issues expires in less than 14 days, for an hour                       |
| `<service>: counter store down`      | the service's counter store, in its namespace, has not answered for 5 minutes                     |
| `<service>: rate limits counted…`    | the service counted requests in its pods for 5 minutes while its counter store answered           |
| `<service>: counters evicted`        | the service's counter store evicted a counter in the last hour                                    |

- **A fault** is filed by hand, from its Fluxer post, as an issue in the service's repository. On
  the Errors dashboard, its operation opens its traces and its service opens its error logs.
- **A `DatasourceError`:** the rule's query failed for its whole pending period, a minute at least.
  Several rules at once, with `received an unexpected error from the datasource`, point at Grafana
  Cloud: read its [status page](https://status.grafana.com). One rule alone, such as with
  `found duplicate series`, is a defect in its query: fix it in the Grafana root's `alerts.tf`.
- **A failed or missed CronJob:** read its Jobs and their logs with `kubectl`, as
  [Ops basics](../ops-basics.md#identities) shows. A failed run is not retried, and the next one
  takes over. A failed `health` run is a failed [health check](#health-checks).
- **A full volume, a lagging replica or failing archiving:** read the database's state on the
  CloudNativePG dashboard first. Barman's archive errors appear in the instance's logs. Never
  delete WAL by hand.
- **A stale base backup:** the replica's 03:00 UTC backup failed or never ran. WAL still archives,
  so no data is lost yet, but a restore replays every segment since the last base backup. Read the
  namespace's events for kind `Backup`, then the replica's `plugin-barman-cloud` container logs, as
  [Ops basics](../ops-basics.md#identities) shows. The next 03:00 UTC run that succeeds resolves it.
- **The cluster above its baseline:** the autoscaler absorbs spikes and transient load; capacity that
  stays is a decision. Raise foundation's `cluster.min_nodes`, or lower the load, in a pull request,
  or let it fall back once the load passes.
- **No room for a lost node, or the autoscaler at its maximum:** raise foundation's
  `cluster.max_nodes`, or lower a workload's requests, in a pull request. Mind the SSD quota the
  nodes' disks share with the volumes.
- **A container near its CPU request or memory limit, or killed for memory:** raise its request or
  limit in a pull request, the cluster root's `databases` for a database, before it saturates. No
  container has a CPU limit, so a busy one slows its neighbors rather than throttling; memory past
  the limit kills the container.
- **A service near its budget:** raise its `service_budgets` entry in the cluster root, in a pull
  request, before new pods are refused; mind that the budgets together fit the node pool.
- **A pod waiting to start, or a workload's autoscaler at its maximum:** the cluster or the workload
  is out of room. Raise the workload's `replicas.max`, or foundation's `cluster.max_nodes` with its
  CPU quota, in a pull request.
- **A database near its connection limit:** raise its `max_connections` in the cluster root's
  `databases`, and its memory with it, in a pull request.
- **The collector silent:** Alloy's pod in the `alloy` namespace, its
  [push token](secrets.md#alloy-push-token) or its egress to Grafana's gateway stopped.
- **Signing keys running out:** JSON Keys' `rotate-keys` CronJob has stopped creating keys, which
  `Scheduled job failing` usually reported first, or someone revoked the last keys. Once no key is
  left, Authentication can sign no session. Read the rotation Jobs' logs, and fix the cause in a
  pull request or a release; the next hourly run that succeeds rotates the keys.
- **GenAI keeping content past retention:** the database's pg_cron purge stopped or falls behind,
  so manuscripts outlive the retention promise. Follow
  [GenAI purge falling behind](#genai-purge-falling-behind).
- **A certificate expiring:** cert-manager renews a certificate at two thirds of its life, so one
  under 14 days has failed to renew for weeks. Read its `Certificate`'s conditions and events, then
  cert-manager's logs in its namespace, as [Ops basics](../ops-basics.md#identities) shows. Once it
  expires, its database or service API refuses every connection, since its callers verify it.
- **A counter store down:** the alert names the service, `authentication` or `narrative-engine`,
  whose store runs in the namespace of its name. Valkey's pod there stopped, or its exporter cannot
  log in. Until it answers, each of the service's pods counts its rate limits on its own, so
  several pods multiply every budget. Read the namespace's `valkey` pod and its containers' logs,
  as [Ops basics](../ops-basics.md#identities) shows. A restart empties the counters, which only
  resets the current windows. `Collector silent` firing with it means Alloy stopped, not the store.
- **Rate limits counted locally while the store answers:** the service's pods cannot reach its
  Valkey or log in. Check the `rest` network policy in the service's file of the cluster root,
  `authentication.tf` or `narrative-engine.tf`, whose egress must reach the store on 6379, then
  the store's `valkey` policy and the limiter's ACL in `counter-store.tf`, which must admit every
  command golib sends. A store answering slower than 100 ms fires it too: **Store commands**, in
  the Rate limits section of the service's Services tab, shows its time.
- **Counters evicted:** the service's counters outgrew its store's memory cap, so Valkey dropped the
  least recently used, and their limits loosened until their windows ended. Raise `maxmemory` in
  the cluster root's `counter-store.tf`, which every store shares, and the pod's memory with it,
  in a pull request.
- **A Services panel empty:** its database query fails, and the two alerts above, which read such
  queries, stay silent. `cnpg_errors_total` names the query and its error in `errorUserQueries`. A
  `permission denied` means the cluster root's `queries/<database>.sql` misses a column it reads.

The contact point's **Title** is `{{ template "discord.title" . }}` and its **Message**
`{{ template "discord.message" . }}`, with **Use embed description** on: the root's `discord`
message template then writes one line per firing instance and the panel, runbook and silence
links. A test notification from **Alerting → Contact points** proves the `discord` contact point's
webhook. A firing rule proves the policy too, such as `Autoscaler at its maximum` while the pool
runs its largest size.

## Health checks

Each service's `health` CronJob, and `health-rest` for JSON Keys' public keys, runs the shared
health check every five minutes, and each new image's `smoke-<hash>` Job runs it once, which the
deploy waits on. The check retries for two minutes, so a failed run means the service failed for
that long. Both skip while a planned downtime runs. Read the failed Job's log, which prints the
service's answer:

```bash
SERVICE=authentication
kubectl --namespace="$SERVICE" get jobs
JOB="<name of the failed Job>"
kubectl --namespace="$SERVICE" logs "job/$JOB"
```

Authentication's answer names each dependency it checked:

| Shows `down`      | Look at                                                                                          |
| ----------------- | ------------------------------------------------------------------------------------------------ |
| `client:postgres` | [Its database](database.md#inspect-a-database): do both instances serve? Is the volume full?     |
| `client:smtp`     | [SMTP](secrets.md#smtp-google-workspace-relay): does the relay rule still admit the NAT address? |
| `api:jsonKeys`    | JSON Keys' `grpc` pods and their logs, then its database.                                        |

No answer at all means the service itself is down: read its pods' logs. An SMTP warning with
`category=timeout` in Authentication's logs means the connection never left: the
[egress allowlist](../architecture.md#network) or NAT dropped it, and neither logs a refusal. When
the address it dialed lies outside `environments/production/foundation/google-service-ranges.json`,
dispatch `refresh-google-ranges.yaml`, whose pull request proposes Google's current list.

## Planned downtime past its end

The three-hourly check fails when a planned downtime is still in place after its announced `end`,
since its services still refuse work. [Clear it](downtime.md#clear-the-downtime) once the work is
done, or schedule it again with a later `end`.

If the checks stopped running, GitHub disabled the schedule after 60 days without repository
activity. Enable it again:

```bash
gh workflow enable drift.yaml --repo a-novel/infra
```

## GenAI purge falling behind

`GenAI keeps content past retention` fires when a settled generation stays stored 30 minutes past
its retention. pg_cron runs the purge in GenAI's database every 10 seconds, oldest first, at most
1,000 rows and 64 MiB a call, so the wait stays near zero. Past 30 minutes, either the purge
stopped, or more than 30 minutes of its fastest pace, about 11 GiB, waits ahead. Expired content
then fills the volume.

GenAI's migrations schedule the purge, and a new database lineage runs them again. Read the latest
migrations Job's log, and the primary's log for pg_cron's errors, as
[Inspect a database](database.md#inspect-a-database) shows:

```bash
kubectl --namespace=genai get jobs
JOB="<name of the latest migrations Job>"
kubectl --namespace=genai logs "job/$JOB"
```

- **The migrations failed:** fix them as [A deploy failed](deployments.md#a-deploy-failed)
  describes. The purge runs again once they schedule it.
- **The purge runs and the backlog still grows:** settled content arrives faster than the purge
  deletes it. The volume alerts give the time left. Raising the purge's batch is a service-genai
  change.

## Gateway refused

`Gateway refused` fires while GKE's Gateway controller refuses a platform's Gateway, or one of its
routes or policies, and retries every few minutes. Until it accepts them all, the platform's load
balancer keeps its last good config: the deploy succeeded, but nothing it changed on the Gateway,
its routes or its policies is live. The warning names the resource and the reason:

```bash
NAMESPACE="<the alert's k8s_namespace_name>"
kubectl --namespace="$NAMESPACE" get events --field-selector=type=Warning
```

Fix that resource in the cluster root, in a pull request. The Gateway API accepts values GKE's
controller refuses, as the redirect's 308 showed (a-novel/infra#1537), so a valid manifest and a
green apply prove nothing until this alert resolves.

## Budget

The [monthly budget](../costs.md) reached 50, 75, 80, 90 or 100%, actual or forecast. In the
billing report, group by service. The usual causes are:

- the cluster running above its baseline of nodes, which `Cluster above its baseline` reports too;
- backup storage growth, as [Costs](../costs.md) explains;
- a database volume that grew.

Recovery drill projects sit outside the budget, so look for a forgotten one in the billing report
too.

## Drift

The cloud no longer matches `master`, and the job summary shows the plan. Either someone changed
something in the console, or a provider default moved. Undo the console change, or codify the new
value in a pull request. A plan that replaces a Job means its last run failed: follow
[A deploy failed](deployments.md#a-deploy-failed).
