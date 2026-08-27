# Respond to production alerts

Use this runbook for the code-managed Google Cloud alerts and native GitHub workflow failures in the
JSON Keys and Authentication production slice. It identifies one human owner and a first safe check
for every signal without adding a paging service, log parser, custom metric, controller, or agent.

Official references: [Cloud Monitoring incidents](https://cloud.google.com/monitoring/alerts/incidents-events),
[alert-policy behavior](https://cloud.google.com/monitoring/alerts),
[Cloud Run metrics](https://cloud.google.com/run/docs/monitoring),
[Cloud Run job monitoring](https://cloud.google.com/run/docs/monitor-jobs),
[notification channels](https://cloud.google.com/monitoring/support/notification-options),
[Cloud Logging queries](https://cloud.google.com/logging/docs/view/logging-query-language), and
[budgets](https://cloud.google.com/billing/docs/how-to/budgets). GitHub owns the low-frequency
synthetic signal; see [scheduled workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule),
[workflow notifications](https://docs.github.com/en/actions/concepts/workflows-and-actions/notifications-for-workflow-runs),
and [Actions notification settings](https://docs.github.com/en/subscriptions-and-notifications/how-tos/managing-github-actions-notifications).

## Ownership and response rules

The monitored `operations_alert_email` is the primary owner for Google service, job, database, and
backup incidents. The monitored `cost_alert_email` is the billing owner. Both receive budget
notifications; only the operations address receives Google application alerts. If either address is
a group, allow mail from Google's documented alerting senders and keep at least two maintainers in
the group.

GitHub sends scheduled-workflow notifications to the account associated with the schedule—the user
who last changed its cron syntax, or who re-enabled it. That maintainer is the synthetic-health
owner and must enable email or web Actions notifications for failed workflows. Assign a second
maintainer to inspect the last scheduled health run during the existing monthly recovery review;
GitHub does not fan scheduled notifications out to the Google operations channel.

Every alert is a symptom, not permission to mutate production. The responder must:

1. record the incident start, policy display name, Google incident link, and latest successful
   deployment receipt in the private incident record;
2. freeze manifest merges and production writers when consistency, recovery, or rollback evidence
   is uncertain;
3. inspect only bounded metadata first—never dump environment variables, OpenTofu state, request or
   response bodies, secret values, full IAM policy, SMTP transcripts, or database rows;
4. use the owning protected workflow or linked runbook for a change; never patch Cloud Run, the VM,
   IAM, schedules, alerts, or a secret reference ad hoc;
5. close the incident only after the signal has recovered, the latest private receipt is known, and
   the cause and follow-up are recorded.

Prepare a private terminal without selecting a default project globally:

```bash
set -euo pipefail
set +x
umask 077

REPOSITORY='a-novel/infra'
REGION='europe-west1'
DATABASE_ZONE='europe-west1-b'
read -r -p 'Production workload project ID: ' WORKLOAD_PROJECT_ID
[[ "$WORKLOAD_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]

gcloud monitoring policies list --project="$WORKLOAD_PROJECT_ID" \
  --filter='displayName:Agora' \
  --format='table(displayName,enabled,severity)'
```

Expected inventory: eight enabled policies—five database-capacity policies, Authentication 5xx,
application jobs, and PostgreSQL recovery jobs. All alert documentation names this runbook and the
production operator. Authentication availability and dependency health use the scheduled GitHub
signal below, not another Google policy.

## Authentication synthetic health

**Signal:** the `health` job in `production drift` fails. Once production releases are enabled, it
runs at minute 43 every three hours and makes one HTTPS request to `/v2/healthcheck`. The check fails
closed unless the response is HTTP 200 and contains only `api:jsonKeys`, `client:postgres`, and
`client:smtp`, each with only `status: up`. The response body, service URL, project ID, and private
foundation configuration are not printed or retained as artifacts.

This is a launch-stage, low-cost signal rather than a page-grade SLO. Detection can take three hours
plus GitHub scheduling delay, and GitHub may delay or drop scheduled work under load. Public-repo
schedules are also disabled after 60 days without repository activity. A disabled workflow or no
successful health run for six hours is a monitoring incident even when the application appears
healthy.

First inspect the workflow control plane without downloading logs or credentials:

```bash
gh workflow list --repo "$REPOSITORY" --all --json name,path,state
gh run list --repo "$REPOSITORY" --workflow drift.yaml --branch master \
  --event schedule --limit 20 \
  --json databaseId,headSha,status,conclusion,createdAt,url
read -r -p 'Latest 43 */3 health run database ID: ' HEALTH_RUN_ID
[[ "$HEALTH_RUN_ID" =~ ^[1-9][0-9]*$ ]]
gh run view "$HEALTH_RUN_ID" --repo "$REPOSITORY" --json headSha,event,jobs,url \
  --jq '{headSha,event,url,jobs:[.jobs[]|{name,conclusion}]}'
gh api "repos/${REPOSITORY}/actions/runs/${HEALTH_RUN_ID}" \
  --jq '{actor:.actor.login,event,head_sha,status,conclusion}'
```

Expected safe result: `production drift` is active, scheduled runs use the current `master` SHA,
the recorded actor is the expected active schedule owner, and a successful run containing the
`health` job is no older than six hours. The daily 05:17 UTC run contains only the drift job; the
`43 */3 * * *` runs contain only health. If GitHub disabled the workflow after repository
inactivity, a maintainer may re-enable this existing workflow with
`gh workflow enable drift.yaml --repo "$REPOSITORY"`, record the change, and then dispatch the
read-only verification below. Do not create a replacement workflow or identity.

First safe checks:

```bash
gcloud run services describe agora-authentication-rest \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" \
  --format='yaml(metadata.name,status.url,status.latestCreatedRevisionName,status.latestReadyRevisionName,status.traffic,status.conditions)'

gcloud logging read '
  resource.type="cloud_run_revision"
  resource.labels.service_name="agora-authentication-rest"
  log_id("run.googleapis.com/requests")
  severity>=WARNING
' --project="$WORKLOAD_PROJECT_ID" --freshness=30m --limit=50 \
  --format='table(timestamp,severity,resource.labels.revision_name,httpRequest.status,httpRequest.latency)'
```

Compare the latest ready revision and traffic target with the newest successful release receipt. If
they differ, stop releases and use [Deploy and roll back production](./deploy-production.md). If
they match, inspect revision condition metadata for both services:

```bash
for service in agora-json-keys-grpc agora-authentication-rest; do
  gcloud run services describe "$service" \
    --project="$WORKLOAD_PROJECT_ID" --region="$REGION" \
    --format='yaml(metadata.name,status.latestReadyRevisionName,status.traffic,status.conditions)'
done
```

Do not curl or print the health response; the job already validated it privately. If JSON Keys is
not Ready or its receipt target differs, use the whole-application rollback procedure. If both
services are Ready, follow [Operate the private PostgreSQL host](./operate-postgresql-host.md) for
private database reachability and [Configure hosted Plunk SMTP](./configure-hosted-smtp.md) for
provider status, cap, credential, and domain checks. Never make JSON Keys public to debug it, add a
NAT route, or enable unauthenticated invocation.

After correcting the owning system through a reviewed path, run one read-only confirmation:

```bash
gh workflow run drift.yaml --repo "$REPOSITORY" --ref master
```

The manual dispatch runs both drift inspection and synthetic health under the same read-only plan
identity. Confirm both jobs succeed at the expected `master` SHA. Do not loop the dispatch: every
health request can keep Authentication's instance-based CPU allocated for up to 15 idle minutes.

## Authentication 5xx rate

**Signal:** `Agora Authentication 5xx error rate`. More than 10% of request count was 5xx for five
minutes. Missing traffic is inactive. This native policy can catch active-traffic failures sooner
than the low-frequency synthetic check, but it cannot prove dependency health during an idle period.

Use the synthetic-health metadata queries, then split only status counts in Logs Explorer or with this
bounded query:

```bash
gcloud logging read '
  resource.type="cloud_run_revision"
  resource.labels.service_name="agora-authentication-rest"
  log_id("run.googleapis.com/requests")
  httpRequest.status>=500
' --project="$WORKLOAD_PROJECT_ID" --freshness=30m --limit=100 \
  --format='table(timestamp,resource.labels.revision_name,httpRequest.requestMethod,httpRequest.status,httpRequest.latency)'
```

Do not add request URLs, query strings, principals, or bodies to the output. Correlate onset with the
receipt and traffic revision. Roll back through the protected workflow when the current release is
causal and backward compatibility permits it. If the revision is unchanged, investigate the
latest synthetic-health result, capacity alerts, and provider status before redeploying identical
code.

## Application jobs and key rotation

**Signal:** `Agora application jobs unhealthy`. Any `agora-authentication-*` or
`agora-json-keys-*` Cloud Run job reported a failed execution, or no successful
`agora-json-keys-rotatekeys` execution was visible for three hours. The first protected release
seeds the rotation time series; an absence alert before that release is not actionable.

```bash
for job in \
  agora-json-keys-migrations \
  agora-json-keys-rotatekeys \
  agora-authentication-migrations; do
  gcloud run jobs executions list --job="$job" \
    --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --limit=5 \
    --format='table(metadata.name,metadata.creationTimestamp,status.completionTime,status.conditions.type,status.conditions.status)'
done

gcloud scheduler jobs describe agora-json-keys-rotation \
  --project="$WORKLOAD_PROJECT_ID" --location="$REGION" \
  --format='yaml(name,state,schedule,timeZone,lastAttemptTime,status)'
```

For a migration failure, freeze deployment and inspect the failed workflow; release compensation
owns rollback. For rotation, confirm the scheduler is enabled, its last attempt exists, and the job
has a recent successful execution. The job is idempotent and evaluates hourly with a 24-hour
minimum rotation interval. Do not execute with overrides, edit the schedule manually, or run the
Authentication initializer: that initializer is one-time, human-only, and never scheduled.

## Database capacity

**Signals:** `Agora database CPU above 70%`, memory above 70%/85%, or disk above 70%/85%. Warning
conditions sustain for ten minutes; critical memory/disk conditions sustain for five. Guest memory
and disk metrics come from Container-Optimized OS's built-in metrics, not an added agent.

Use [Operate the private PostgreSQL host](./operate-postgresql-host.md) as the source of truth. Begin
with its exact host selection, group stability, filesystem, container limit, connection, and recent
snapshot checks. Do not resize based on one sample. At sustained pressure, update the reviewed
machine type, container allocations, connection caps, or growth-only disk size in foundation code;
the host runbook owns outage planning and rollback. Never attach a public IP or open PostgreSQL for
diagnosis.

## PostgreSQL backups and restore drills

**Signal:** `Agora PostgreSQL recovery jobs unhealthy`. Any `agora-postgres-*` execution failed, or
the hourly backup monitor has not completed for three hours. This covers four-hour logical backups,
monthly clean restores, and the RPO/storage monitor without a custom metric or log parser.

```bash
for job in \
  agora-postgres-backup-json-keys \
  agora-postgres-backup-authentication \
  agora-postgres-restore-json-keys \
  agora-postgres-restore-authentication \
  agora-postgres-backup-monitor; do
  gcloud run jobs executions list --job="$job" \
    --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --limit=5 \
    --format='table(metadata.name,metadata.creationTimestamp,status.completionTime,status.conditions.type,status.conditions.status)'
done
```

Continue with [Back up and restore PostgreSQL](./backup-and-restore-postgresql.md). It owns exact
manifest inspection, schedules, six-hour RPO, retained-storage ceiling, clean restore, snapshot,
and escalation checks. Freeze database-changing releases until both databases again have a fresh
logical backup and the monitor succeeds. Do not delete a partial object, rewrite a completion
manifest, or call a backup successful from object presence alone.

## Budget alerts

**Signal:** `Agora production infrastructure` at current or forecast spend of 50%, 75%, 90%, or
100% of 60 units in the billing-account currency. Both human channels receive this alert. A budget
does not stop resources or charges.

The billing owner verifies the alert against the Cloud Billing console and the code-managed scope
of exactly the management and workload projects. At 50%, identify the service and rate of growth.
At 75%, freeze nonessential scale and image/storage growth. At 90%, require maintainer approval for
every cost-increasing deployment. At 100%, disable optional workloads through a reviewed change and
decide whether application availability or the monthly budget takes precedence. Never delete the
database disk, backup bucket, state, receipts, or recovery evidence to reduce a bill.

Follow [Production cost model](../costs/production.md) and reconcile any budget/configuration change
through a protected foundation plan. Hosted Plunk usage is external to the Google budget; its
separate category cap belongs to [Configure hosted Plunk SMTP](./configure-hosted-smtp.md).

## GitHub release, drift, and validation failures

GitHub Actions is the existing control plane, so workflow failures use its native Actions
notifications instead of a second alerting product. The scheduled-workflow owner and backup named
above must review notification ownership whenever that maintainer changes.

For a failed `production release`, `production foundation`, `production recovery`, daily drift, or
three-hour synthetic-health run:

```bash
gh run list --repo "$REPOSITORY" --branch master --limit 20 \
  --json databaseId,workflowName,displayTitle,headSha,event,status,conclusion,createdAt,url
```

Select the exact run privately, verify its `headSha`, and inspect only the first failed step. Never
download or paste runner credentials, temporary configuration, provider diagnostics, plans, or
state. A drift exit means desired and live resources differ; it is not permission to apply. Open a
reviewed correction, create a fresh private plan, and use the protected workflow. A release failure
after mutation already follows the single compensation edge; verify the newest receipt before any
retry. A health failure performs no mutation; diagnose it through
[Authentication synthetic health](#authentication-synthetic-health).

## Verify channels without adding machinery

Google does not provide a generic “send test” operation for notification channels. Verify both
code-managed email channels after foundation apply:

```bash
gcloud beta monitoring channels list --project="$WORKLOAD_PROJECT_ID" \
  --filter='displayName:("Agora production cost alerts" OR "Agora production operations alerts")' \
  --format='table(name,displayName,type,enabled,verificationStatus)'
```

Expected result: exactly two enabled email channels. Complete any Google verification flow on those
same channels; do not create console duplicates. Record delivery at the first naturally firing
Google application policy and the first real budget threshold. Do not deliberately break
Authentication or create a temporary VM, webhook, Pub/Sub topic, bot, synthetic service, or
hand-written alert policy solely to test email.

GitHub notification delivery is separate. The schedule owner should temporarily select ordinary
email or web Actions notifications, wait for one successful `43 */3 * * *` run, record receipt, and
then choose failed-workflow-only notifications if preferred. The monthly recovery review confirms
that `production drift` remains enabled, its schedule owner is active, and its last health job is
newer than six hours. This catches GitHub's public-repository inactivity disablement without another
monitor.

After each real incident, record whether open and close notifications arrived at the intended
address. A missing notification is itself an operations issue: keep the production change frozen,
correct the existing address through reviewed code, verify the existing channel, and repeat the
next safe real-signal check.
