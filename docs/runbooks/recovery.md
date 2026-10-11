# Recovery

This runbook restores a backup into a **disposable drill project**, and checks it there.
Production's disks and data are never touched. Use it to rehearse recovery, to inspect old data, or
as the first step of a real data restore. To undo a database host rollout, use its snapshot instead:
[Undo a rollout](database.md#undo-a-rollout).

## 1. Pick the backup

Set the service, then list its backups on its repository VM (see
[Database hosts](database.md#inspect-and-connect)):

```bash
SERVICE=json-keys
```

```bash
sudo docker exec agora-backup-repository pgbackrest --stanza="$SERVICE" --output=json info |
  jq '.[0] | {system_id: .db[0]["system-id"], sets: [.backup[] | .label]}'
```

Note the `system_id` and the set label, for example `20261005-020001F`.

## 2. Create the drill project

`DRILL` must match `a-novel-recovery-<id>`, with at most 30 characters. Creating it needs
`roles/resourcemanager.projectCreator` on the organization, which organization admins can grant
themselves for the drill and remove afterwards:

```bash
gcloud organizations add-iam-policy-binding 1031663934757 --role=roles/resourcemanager.projectCreator \
  --member="user:$(gcloud config get-value account)" --condition=None
```

```bash
DRILL=a-novel-recovery-261101
gcloud projects create "$DRILL" --organization=1031663934757
gcloud billing projects link "$DRILL" --billing-account=01BDFE-5B21E7-8393CB
gcloud services enable compute.googleapis.com artifactregistry.googleapis.com dns.googleapis.com --project="$DRILL"
gcloud projects add-iam-policy-binding "$DRILL" --role=roles/owner \
  --member="serviceAccount:infra-foundation@$MGMT.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$DRILL" --role=roles/artifactregistry.reader \
  --member="serviceAccount:pgbr-$SERVICE-recovery@$MGMT.iam.gserviceaccount.com"
# Temporary: lets the deploy identity attach the backup reader to the drill VM.
gcloud iam service-accounts add-iam-policy-binding "pgbr-$SERVICE-recovery@$MGMT.iam.gserviceaccount.com" \
  --project="$MGMT" --role=roles/iam.serviceAccountUser \
  --member="serviceAccount:infra-foundation@$MGMT.iam.gserviceaccount.com"
# The backup reader stays disabled outside drills.
gcloud iam service-accounts enable "pgbr-$SERVICE-recovery@$MGMT.iam.gserviceaccount.com" --project="$MGMT"
```

The backup reader `pgbr-<service>-recovery` can read the service's backups and restore deleted
objects, but not delete them. While it is enabled, the drift check reports bootstrap as drifted.

Copy the restore worker into the drill project. Use a `native-restore` image published from the
current `master` ([Host tools](host-tools.md#publish-a-version)), and
[verify it](host-tools.md#verify-the-published-image) with the digest and commit of its run.

```bash
DIGEST=sha256:<native-restore digest from the publication run>
gcloud artifacts repositories create agora-tooling --repository-format=docker --location=europe-west1 --project="$DRILL"
skopeo copy --all --preserve-digests --dest-creds="oauth2accesstoken:$(gcloud auth print-access-token)" \
  "docker://ghcr.io/a-novel/infra/native-restore@$DIGEST" \
  "docker://europe-west1-docker.pkg.dev/$DRILL/agora-tooling/native-restore:drill"
```

## 3. Create the drill host

```bash
DRILL_JSON="$(jq -nc --arg project "$DRILL" --arg service "$SERVICE" --arg digest "$DIGEST" \
  --arg system_id "<system_id>" --arg set "<set label>" '{
    service: $service, project: $project, source_project: "a-novel-production-prod",
    protected_projects: ["a-novel-management-prod", "a-novel-production-prod", "a-novel-public-api-prod", "a-novel-public-prod"],
    management_project: "a-novel-management-prod", management_number: "232403541574",
    region: "europe-west1", zone: "europe-west1-d",
    cos_image: "projects/cos-cloud/global/images/cos-129-19506-505-8",
    restore_image: ("europe-west1-docker.pkg.dev/" + $project + "/agora-tooling/native-restore@" + $digest),
    disk_gib: 20, system_id: $system_id, set: $set, verify_sql: true
  }')"
gh workflow run recovery.yaml --repo a-novel/infra -f operation=plan -f drill="$DRILL_JSON"
```

`cos_image` is the repository VMs' image, `backup_repository.cos_image` in a service root. Read the
plan in the run's summary. Once it shows only the drill host and its network, apply it:

```bash
gh workflow run recovery.yaml --repo a-novel/infra -f operation=apply -f drill="$DRILL_JSON"
```

The host is created **stopped**, with no external IP and no route to production.

## 4. Restore

```bash
gcloud compute instances start agora-native-recovery --zone="$ZONE" --project="$DRILL"
gcloud compute ssh agora-native-recovery --zone="$ZONE" --project="$DRILL" --tunnel-through-iap
```

On the drill host:

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
- Neither one ever replays: to try again, start over with a new drill project.
- The VM stops itself after four hours.

Putting restored data back into production has no procedure yet. It is a one-off change, planned
and reviewed on its own: for example a dump of the needed rows imported during a planned downtime,
or a disk made from the drill's restored data and swapped in as in
[Undo a rollout](database.md#undo-a-rollout).

## 5. Clean up

```bash
gcloud iam service-accounts disable "pgbr-$SERVICE-recovery@$MGMT.iam.gserviceaccount.com" --project="$MGMT"
gcloud iam service-accounts remove-iam-policy-binding "pgbr-$SERVICE-recovery@$MGMT.iam.gserviceaccount.com" \
  --project="$MGMT" --role=roles/iam.serviceAccountUser \
  --member="serviceAccount:infra-foundation@$MGMT.iam.gserviceaccount.com"
gcloud projects delete "$DRILL"
gcloud storage rm -r "$STATE/recovery/$DRILL/"
gcloud organizations remove-iam-policy-binding 1031663934757 --role=roles/resourcemanager.projectCreator \
  --member="user:$(gcloud config get-value account)" --condition=None
```

Remove the project-creation role only if you granted it for this drill.

A deleted project keeps billing its disks until Google purges it, which can take up to 30 days.
