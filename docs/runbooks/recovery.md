# Recovery

This runbook restores a backup into a **disposable drill project**, and checks it there.
Production's disks and data are never touched. Use it to rehearse recovery, to inspect old data, or
as the first step of a real data restore.

Steps 1 to 5 restore a database host's pgBackRest backup. [Cluster databases](#cluster-databases)
restores a cluster database's Barman backup, to a point in time.

## 1. Pick the backup

List the service's backups on its repository VM:

```bash
SERVICE=json-keys
gcloud compute ssh "agora-pgbackrest-$SERVICE" --zone=europe-west1-d --project=a-novel-production-prod \
  --tunnel-through-iap \
  --command="sudo docker exec agora-backup-repository pgbackrest --stanza=$SERVICE --output=json info" |
  jq '.[0] | {system_id: .db[0]["system-id"], sets: [.backup[] | .label]}'
```

Note the `system_id` and the set label, for example `20261005-020001F`.

## 2. Create the drill project

Creating a project needs `roles/resourcemanager.projectCreator` on the organization. Organization
admins grant it to themselves for the drill, and remove it afterwards. Skip this if you already hold
it:

```bash
gcloud organizations add-iam-policy-binding 1031663934757 --role=roles/resourcemanager.projectCreator \
  --member="user:$(gcloud config get-value account)" --condition=None
```

Create the project. `DRILL` must match `a-novel-recovery-<id>`, with at most 30 characters:

```bash
DRILL=a-novel-recovery-261101
gcloud projects create "$DRILL" --organization=1031663934757
gcloud billing projects link "$DRILL" --billing-account=01BDFE-5B21E7-8393CB
gcloud services enable compute.googleapis.com artifactregistry.googleapis.com dns.googleapis.com \
  --project="$DRILL"
```

Let the deploy identity build the drill host, and the service's backup reader,
`pgbr-<service>-recovery`, pull the restore worker. The deploy identity also needs to attach the
backup reader to the drill VM, for the drill only:

```bash
DEPLOYER="serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
READER="pgbr-$SERVICE-recovery@a-novel-management-prod.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$DRILL" --role=roles/owner --member="$DEPLOYER"
gcloud projects add-iam-policy-binding "$DRILL" --role=roles/artifactregistry.reader \
  --member="serviceAccount:$READER"
gcloud iam service-accounts add-iam-policy-binding "$READER" --project=a-novel-management-prod \
  --role=roles/iam.serviceAccountUser --member="$DEPLOYER"
```

The backup reader can read the service's backups and restore deleted objects, but not delete them.
It stays disabled outside drills. Enable it:

```bash
gcloud iam service-accounts enable "$READER" --project=a-novel-management-prod
```

While it is enabled, the drift check reports bootstrap as drifted.

Copy the restore worker into the drill project with `skopeo`. Use a `native-restore` image
[published](host-tools.md#publish-a-version) from the current `master`, and
[verify it](host-tools.md#verify-the-published-image) with the digest and commit of its run:

```bash
DIGEST="sha256:<native-restore digest from the publication run>"
gcloud artifacts repositories create agora-tooling --repository-format=docker \
  --location=europe-west1 --project="$DRILL"
skopeo copy --all --preserve-digests --dest-creds="oauth2accesstoken:$(gcloud auth print-access-token)" \
  "docker://ghcr.io/a-novel/infra/native-restore@$DIGEST" \
  "docker://europe-west1-docker.pkg.dev/$DRILL/agora-tooling/native-restore:drill"
```

## 3. Create the drill host

`recovery.yaml` plans or applies the drill host from one JSON input. Only admins can run it. The
input takes the backup from step 1, and the repository VMs' image, `backup_repository.cos_image` in
the service root:

```bash
SYSTEM_ID="<system_id from step 1>"
SET="<set label from step 1>"
COS_IMAGE="$(sed -nE 's/^ *cos_image *= *"([^"]+)".*/\1/p' "environments/production/$SERVICE/terraform.tfvars")"
DRILL_JSON="$(jq -nc --arg project "$DRILL" --arg service "$SERVICE" --arg digest "$DIGEST" \
  --arg system_id "$SYSTEM_ID" --arg set "$SET" --arg cos_image "$COS_IMAGE" '{
    service: $service, project: $project, source_project: "a-novel-production-prod",
    protected_projects: ["a-novel-management-prod", "a-novel-production-prod", "a-novel-public-api-prod", "a-novel-public-prod"],
    management_project: "a-novel-management-prod", management_number: "232403541574",
    region: "europe-west1", zone: "europe-west1-d", cos_image: $cos_image,
    restore_image: ("europe-west1-docker.pkg.dev/" + $project + "/agora-tooling/native-restore@" + $digest),
    disk_gib: 20, system_id: $system_id, set: $set, verify_sql: true
  }')"
gh workflow run recovery.yaml --repo a-novel/infra -f root=host -f operation=plan -f drill="$DRILL_JSON"
```

Read the plan in the run's log:

```bash
gh run list --repo a-novel/infra --workflow recovery.yaml --limit 1
RUN="<ID of that run>"
gh run view "$RUN" --repo a-novel/infra --log
```

Once it shows only the drill host and its network, apply it:

```bash
gh workflow run recovery.yaml --repo a-novel/infra -f root=host -f operation=apply -f drill="$DRILL_JSON"
```

The host is created **stopped**, with no external IP and no route to production.

## 4. Restore

Start the drill host and connect to it:

```bash
gcloud compute instances start agora-native-recovery --zone=europe-west1-d --project="$DRILL"
gcloud compute ssh agora-native-recovery --zone=europe-west1-d --project="$DRILL" --tunnel-through-iap
```

On the drill host, prepare the data disk, restore, then verify:

```bash
sudo mkfs.ext4 -m 0 /dev/disk/by-id/google-agora-native-recovery-data
sudo mkdir -p /mnt/disks/agora-recovery
sudo mount /dev/disk/by-id/google-agora-native-recovery-data /mnt/disks/agora-recovery
sudo systemctl start agora-native-restore.service
sudo systemctl start agora-native-verify.service
sudo cat /mnt/disks/agora-recovery/work/attempt/files-restored.json /mnt/disks/agora-recovery/work/attempt/verification/sql-verified.json
```

- `agora-native-restore` restores the exact set and checks the database identity.
- `agora-native-verify` runs PostgreSQL offline, with no network, and runs the service's schema
  checks.
- Neither one ever replays. To try again, start over with a new drill project.
- The VM stops itself after four hours.

Putting restored data back into production is a one-off change, planned and reviewed on its own.
It is a dump of the needed rows, imported during a planned downtime.

## 5. Clean up

Disable the backup reader, and take back the deploy identity's right to attach it:

```bash
gcloud iam service-accounts disable "$READER" --project=a-novel-management-prod
gcloud iam service-accounts remove-iam-policy-binding "$READER" --project=a-novel-management-prod \
  --role=roles/iam.serviceAccountUser --member="$DEPLOYER"
```

Delete the drill project and its state:

```bash
gcloud projects delete "$DRILL"
gcloud storage rm -r "gs://a-novel-management-prod-232403541574-tofu-state/recovery/$DRILL/"
```

A deleted project keeps billing its disks until Google purges it, which can take up to 30 days.

If you granted yourself the project-creation role for this drill, remove it:

```bash
gcloud organizations remove-iam-policy-binding 1031663934757 --role=roles/resourcemanager.projectCreator \
  --member="user:$(gcloud config get-value account)" --condition=None
```

## Cluster databases

A drill restores each service's cluster database from its Barman bucket, to a point in time, into a
throwaway cluster in the drill project. One `recovery.yaml` run creates the cluster, restores and
checks the databases, then destroys the cluster, even when the drill fails or is cancelled. The
billing account's free tier already covers production's cluster, so the drill's cluster pays the
full management fee. With its node, that comes to about USD 0.40 an hour, billed only while the
run lasts, under an hour.

The cluster reaches nothing but Google's APIs, and runs the operator production runs. It pulls every
image through the drill project's own caches of quay.io and ghcr.io, by the digests production
pins, so it reads nothing in production's registries. Each restored database reads only its own
service's Barman bucket, through the `barmanReader` role, and nothing writes the buckets.

### Create the drill project

Create and link the project as in [step 2](#2-create-the-drill-project), then enable the cluster's
APIs and let the deploy identity build in it:

```bash
DRILL=a-novel-recovery-261101
gcloud services enable compute.googleapis.com container.googleapis.com artifactregistry.googleapis.com \
  dns.googleapis.com --project="$DRILL"
gcloud projects add-iam-policy-binding "$DRILL" --role=roles/owner \
  --member="serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
```

The project serves any number of drills: each one leaves it empty.

### Run the drill

The input names the drill project. It restores every service's database unless `services` lists
some, and recovers to the latest WAL unless `target_time` sets an RFC 3339 UTC time:

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

### Inspect a restore

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

### Clean up

Once the drills are done, delete the project and both states:

```bash
gcloud projects delete "$DRILL"
gcloud storage rm -r "gs://a-novel-management-prod-232403541574-tofu-state/recovery-database/$DRILL/" \
  "gs://a-novel-management-prod-232403541574-tofu-state/recovery-cluster/$DRILL/"
```

Remove the project-creation role as in [step 5](#5-clean-up) if you granted it for the drill.
