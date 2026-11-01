# Recovery

This runbook restores the cluster databases' Barman backups into a **disposable drill project**, to
a point in time, and checks them there. Production's databases and buckets are never touched. Use it
to rehearse recovery, to inspect old data, or as the first step of a real data restore.

One `recovery.yaml` run creates a throwaway cluster in the drill project, restores and checks the
databases, then destroys the cluster, even when the drill fails or is cancelled. The billing
account's free tier already covers production's cluster, so the drill's cluster pays the full
management fee. With its node, that comes to about USD 0.40 an hour, billed only while the run
lasts, under an hour.

The cluster reaches nothing but Google's APIs, and runs the operator production runs. It pulls every
image through the drill project's own caches of quay.io and ghcr.io, by the digests production
pins, so it reads nothing in production's registries. Each restored database reads only its own
service's Barman bucket, through the `barmanReader` role, and nothing writes the buckets.

## Create the drill project

Creating a project needs `roles/resourcemanager.projectCreator` on the organization. Organization
admins grant it to themselves for the drill, and remove it afterwards. Skip this if you already hold
it:

```bash
gcloud organizations add-iam-policy-binding 1031663934757 --role=roles/resourcemanager.projectCreator \
  --member="user:$(gcloud config get-value account)" --condition=None
```

Create the project, enable the cluster's APIs and let the deploy identity build in it. `DRILL` must
match `a-novel-recovery-<id>`, with at most 30 characters:

```bash
DRILL=a-novel-recovery-261101
gcloud projects create "$DRILL" --organization=1031663934757
gcloud billing projects link "$DRILL" --billing-account=01BDFE-5B21E7-8393CB
gcloud services enable compute.googleapis.com container.googleapis.com artifactregistry.googleapis.com \
  dns.googleapis.com --project="$DRILL"
gcloud projects add-iam-policy-binding "$DRILL" --role=roles/owner \
  --member="serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
```

The project serves any number of drills: each one leaves it empty.

## Run the drill

The input names the drill project. It restores every service's database unless `services` lists
some, and recovers to the latest WAL unless `target_time` sets an RFC 3339 UTC time. Only admins can
run it:

```bash
DRILL_JSON="$(jq -nc --arg project "$DRILL" '{project: $project}')"
gh workflow run recovery.yaml --repo a-novel/infra -f root=cluster -f operation=drill -f drill="$DRILL_JSON"
```

A target needs a base backup older than it, and a commit after it in each database's WAL:
PostgreSQL fails a recovery that ends before its target. A point-in-time drill therefore restores
the databases that wrote after the target, such as GenAI, whose pg_cron jobs write every few
seconds:

```bash
DRILL_JSON="$(jq -nc --arg project "$DRILL" --arg target_time "2026-11-02T12:00:00Z" \
  '{project: $project, services: ["genai"], target_time: $target_time}')"
gh workflow run recovery.yaml --repo a-novel/infra -f root=cluster -f operation=drill -f drill="$DRILL_JSON"
```

The drill passes when its `run` job succeeds: each database recovered, serves and passed its
check. Each check connects as the database's owner, and fails at the first of these that does not
hold:

- every extension production creates came back;
- the migrations history came back;
- every constraint is validated;
- the owner holds no rights beyond its database;
- a database that runs pg_cron brought its schedules back, active;
- every row of every table reads, its stored values included.

The `Report the databases` step prints, for each service, where its recovery stopped, its check's
row counts and latest migration, and whatever kept the database from serving. Follow the run:

```bash
gh run list --repo a-novel/infra --workflow recovery.yaml --limit 1
RUN="<ID of that run>"
gh run view "$RUN" --repo a-novel/infra --log
```

The `teardown` job then destroys the databases, which deletes their volumes, then the cluster, and
fails if a volume's disk is left. When it fails, re-run it alone:

```bash
gh run rerun "$RUN" --repo a-novel/infra --failed
```

A disk it names holds restored production data. Delete it with the command its error prints.

## Inspect a restore

`operation=apply` restores and checks the databases like a drill, and keeps them. The cluster bills
until `operation=destroy` removes it. Inspect a database:

```bash
gcloud container clusters get-credentials recovery --location=europe-west9-a --project="$DRILL" --dns-endpoint
kubectl exec --namespace=json-keys drill-1 --container=postgres -- psql --dbname=app --command='\dt'
```

Then destroy it:

```bash
gh workflow run recovery.yaml --repo a-novel/infra -f root=cluster -f operation=destroy -f drill="$DRILL_JSON"
```

Putting restored data back into production is a one-off change, planned and reviewed on its own.

## Clean up

Once the drills are done, delete the project and both states:

```bash
gcloud projects delete "$DRILL"
gcloud storage rm -r "gs://a-novel-management-prod-232403541574-tofu-state/recovery-database/$DRILL/" \
  "gs://a-novel-management-prod-232403541574-tofu-state/recovery-cluster/$DRILL/"
```

A deleted project keeps billing its disks until Google purges it, which can take up to 30 days.

If you granted yourself the project-creation role for this drill, remove it:

```bash
gcloud organizations remove-iam-policy-binding 1031663934757 --role=roles/resourcemanager.projectCreator \
  --member="user:$(gcloud config get-value account)" --condition=None
```
