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
gh workflow run recovery.yaml --repo a-novel/infra -f operation=plan -f drill="$DRILL_JSON"
```

Read the plan in the run's log:

```bash
gh run list --repo a-novel/infra --workflow recovery.yaml --limit 1
RUN="<ID of that run>"
gh run view "$RUN" --repo a-novel/infra --log
```

Once it shows only the drill host and its network, apply it:

```bash
gh workflow run recovery.yaml --repo a-novel/infra -f operation=apply -f drill="$DRILL_JSON"
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

The drill restores one service's database into a one-node cluster in the drill project. The cluster
reaches nothing but Google's APIs, pulls every image through its own caches, and runs the operator
production runs. Only the restored database reads the service's Barman bucket, and nothing writes
it. A cluster costs about $0.25 an hour while it exists.

A drill needs a base backup older than its target. Without a target, it recovers to the latest WAL
in the bucket.

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

### Restore

`recovery.yaml` takes the same input for both roots. `target_time` is RFC 3339 UTC, or empty for
the latest:

```bash
SERVICE=json-keys
DRILL_JSON="$(jq -nc --arg project "$DRILL" --arg service "$SERVICE" --arg target_time "2026-11-02T12:00:00Z" \
  '{project: $project, service: $service, target_time: $target_time}')"
gh workflow run recovery.yaml --repo a-novel/infra -f root=cluster -f operation=plan -f drill="$DRILL_JSON"
```

Read the plan in the run's log, as in [step 3](#3-create-the-drill-host). It creates the network,
the caches, the cluster and its node, and one grant on the service's Barman bucket. Apply it, which
takes about ten minutes, then plan and apply the restored database:

```bash
gh workflow run recovery.yaml --repo a-novel/infra -f root=cluster -f operation=apply -f drill="$DRILL_JSON"
gh workflow run recovery.yaml --repo a-novel/infra -f root=database -f operation=plan -f drill="$DRILL_JSON"
gh workflow run recovery.yaml --repo a-novel/infra -f root=database -f operation=apply -f drill="$DRILL_JSON"
```

The database apply passes once the database has recovered to its target and serves. Inspect it:

```bash
gcloud container clusters get-credentials recovery --location=europe-west9-a --project="$DRILL" --dns-endpoint
kubectl exec --namespace="$SERVICE" drill-1 --container=postgres -- psql --dbname=app --command='\dt'
```

### Clean up

Destroy the database, then the cluster, which takes back the bucket grant. Then delete the project
and both states:

```bash
gh workflow run recovery.yaml --repo a-novel/infra -f root=database -f operation=destroy -f drill="$DRILL_JSON"
gh workflow run recovery.yaml --repo a-novel/infra -f root=cluster -f operation=destroy -f drill="$DRILL_JSON"
gcloud projects delete "$DRILL"
gcloud storage rm -r "gs://a-novel-management-prod-232403541574-tofu-state/recovery-database/$DRILL/" \
  "gs://a-novel-management-prod-232403541574-tofu-state/recovery-cluster/$DRILL/"
```

Remove the project-creation role as in [step 5](#5-clean-up) if you granted it for the drill.
