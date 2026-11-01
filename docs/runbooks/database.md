# Databases

This runbook is about the services' PostgreSQL databases. Each one is a CloudNativePG database named
`database` in its service's namespace, `json-keys`, `authentication` or `genai`: a primary and a
replica, which archive to the service's Barman bucket.
[Architecture](../architecture.md#databases-and-backups) gives their sizes and backups.

## Inspect a database

Operators read each namespace through Kubernetes' `view` role. It shows the database's pods, their
logs and the namespace's events, but never its Secrets, and it opens no session in a pod. It cannot
read CloudNativePG's `Cluster` objects either. Grafana's **CloudNativePG** dashboard draws each
database's state, replication, archiving and volume use.

```bash
SERVICE=json-keys
gcloud container clusters get-credentials a-novel-production --project=a-novel-production-prod --location=europe-west9-a --dns-endpoint
kubectl --namespace="$SERVICE" get pods --selector=cnpg.io/cluster=database --label-columns=cnpg.io/instanceRole
kubectl --namespace="$SERVICE" get events --sort-by=.lastTimestamp
```

The pod list names each instance and its role, `primary` or `replica`. Read one instance's log:

```bash
INSTANCE="<instance from the pod list>"
kubectl --namespace="$SERVICE" logs "$INSTANCE" --container=postgres --since=1h
```

## Backups

Each database archives its WAL to its Barman bucket continuously. Its `daily` scheduled backup takes
a base backup from the replica at 03:00 UTC, and a new lineage takes one at once. Barman keeps 14
days of base backups and the WAL they need. Grafana's `WAL archiving failing` alert fires when a
primary's latest archive attempt failed for 5 minutes.

Restores go through a [recovery drill](recovery.md), in a disposable project. Putting restored data
back into production is a one-off change, planned and reviewed on its own.

## Change a database

A database's settings are its entry in the cluster root's `databases`: its CPU request, its memory,
its volume, its connection limit and its extensions. Its image is the `database` pin of its service
root, which each release moves.

These changes roll without a downtime. CloudNativePG updates the replica, then switches over to it,
which pauses writes for seconds. That covers settings, resources, operator upgrades and a new
release image of the same PostgreSQL major. GKE upgrades nodes only from Tuesday to Thursday, 01:00
to 07:00 UTC, and CloudNativePG switches over before a primary's node drains.

Volumes only grow, in place. CloudNativePG refuses a smaller one, and another storage class applies
only to instances recreated by hand. The volumes share the region's SSD quota with the nodes' boot
disks.

## PostgreSQL major upgrades

A major upgrade stops the database. CloudNativePG shuts every instance down and runs `pg_upgrade`. A
plan that raises `major` in a database's `imageCatalogRef` needs the `allow-downtime` label and a
planned downtime listing `service-<root>.database` in progress. The deploy applies it only while
that downtime runs.

WAL from the old major recovers nothing past the upgrade. The next base backup after it is the first
one the new major can recover from.

1. **Schedule a planned downtime** for the service, as
   [Schedule a downtime](downtime.md#schedule-or-change-a-downtime) describes. List the services
   that depend on it too. Start it after the 03:00 UTC base backup, so the upgrade begins from a
   fresh one.
2. **Once the downtime has started, add the `allow-downtime` label** to the pull request. Its checks
   re-run and pass.

   ```bash
   PR="<pull request number>"
   gh pr edit "$PR" --repo a-novel/infra --add-label allow-downtime
   ```

   A label added before the downtime started re-ran the checks too early. Re-run the failed plan
   checks once it has started:

   ```bash
   BRANCH="$(gh pr view "$PR" --repo a-novel/infra --json headRefName --jq .headRefName)"
   RUN="$(gh run list --repo a-novel/infra --workflow main.yaml --branch "$BRANCH" --limit 1 \
     --json databaseId --jq '.[0].databaseId')"
   gh run rerun "$RUN" --repo a-novel/infra --failed
   ```

   A push removes the label, because the label approved the plans of an earlier commit. Review the
   new plans and add it again.

3. **Approve and merge.** A maintainer or admin reviews and approves the pull request. An admin who
   opened it may record the approval themselves instead:

   ```bash
   gh workflow run approve-pr.yaml --repo a-novel/infra -f pull_request="$PR"
   ```

   Once the approval shows on the pull request, merge it:

   ```bash
   gh pr merge "$PR" --repo a-novel/infra
   ```

   The deploy applies the upgrade and waits until both instances serve and WAL reaches Barman.

4. **Check the database**, as [Inspect a database](#inspect-a-database) shows. The deploy's smoke
   checks skip while the downtime runs, since the services refuse work.
5. **Clear the downtime**, as [Clear the downtime](downtime.md#clear-the-downtime) describes. Its
   deploy restarts the services and runs the smoke checks the downtime skipped.

An upgrade merged before its downtime started fails its deploy, and every later deploy that applies
the cluster root. Nothing starts a deploy when a downtime begins, so once it has started, run one by
hand:

```bash
gh workflow run deploy.yaml --repo a-novel/infra
```

## Lineages

Each database archives under the cluster root's `backup_server_name`, `database-production`: its
lineage. **Never change it in production.** A new name deletes every database, waits four minutes,
then recreates each one empty, runs the migrations again and takes a base backup at once. Barman
refuses to archive into a path another database's WAL already fills, so a lineage name serves once.

Bootstrap's `retired_barman_lineages` expires a former lineage 15 days after its objects were
written. List a name there only once nothing needs its backups.

## When a database never serves

The deploy's `Describe the databases` step prints, for each database, its failing conditions, its
stuck pods and its latest warnings. Follow its pods and their logs too: a new database starts as
`database-1`, then a `join` Job brings up `database-2`.

- **A replica that can't join** logs `tls: unknown certificate authority` when its certificate and
  its primary's client CA differ. Our CA issues both, so this points at a certificate that has not
  reached the namespace.
- **A database whose creation timed out is tainted**, and its next plan replaces it. A replacement
  starts empty, and Barman refuses to archive into the path its predecessor filled, so it never
  turns ready. The replacement needs `allow-resource-deletion`: never add that label to a plan that
  replaces a database holding data.

Data damaged by a change goes back through [recovery](recovery.md), as a one-off change planned on
its own.
