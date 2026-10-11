# Database hosts

Each service has a database host in group `agora-database-<service>` and a backup repository VM
`agora-pgbackrest-<service>`. `<service>` is `json-keys` or `authentication`. The SQL role and
database are `agora_json_keys` or `agora_authentication`.

## Inspect and connect

Humans have read access plus SSH through Identity-Aware Proxy. Nobody has a public path.

```bash
SERVICE=json-keys
HOST="$(gcloud compute instance-groups managed list-instances "agora-database-$SERVICE" \
  --zone="$ZONE" --project="$PROD" --format='value(instance.basename())')"
gcloud compute ssh "$HOST" --zone="$ZONE" --project="$PROD" --tunnel-through-iap
```

`gcloud` creates and registers an OS Login key on first use.

A rolled host can present new SSH host keys, and `gcloud` then refuses to connect with
"REMOTE HOST IDENTIFICATION HAS CHANGED". Compare the fingerprint it prints with the key the
instance publishes, and drop the stale entry only when they match:

```bash
gcloud compute instances get-guest-attributes "$HOST" --zone="$ZONE" --project="$PROD" \
  --query-path=hostkeys/ssh-ed25519 --format='value(value)' | sed 's/^/ssh-ed25519 /' | ssh-keygen -lf -
ID="$(gcloud compute instances describe "$HOST" --zone="$ZONE" --project="$PROD" --format='value(id)')"
ssh-keygen -R "compute.$ID" -f ~/.ssh/google_compute_known_hosts
```

On the host:

```bash
sudo systemctl status agora-database.service
sudo docker ps
df -h /mnt/disks/agora-data
sudo journalctl -u agora-database.service --since=-1h
sudo docker exec -it --user postgres "agora-postgres-$SERVICE" psql -U agora_json_keys -d agora_json_keys
```

The repository VM works the same way. SSH to `agora-pgbackrest-$SERVICE`; its unit is
`agora-backup-repository.service`.

Do not read files under `/run/agora*`, inspect containers' full configuration, or request metadata
tokens. They contain credentials.

## Back up now and verify

Timers already take a full backup on Sundays, a differential the other days, and a check every
hour. To take one by hand, for example before maintenance, run on the database host:

```bash
sudo systemctl start --wait agora-backup-check.service
sudo systemctl start --wait agora-backup-full.service
sudo systemctl start --wait agora-backup-verify.service
sudo journalctl -u agora-backup-full.service -u agora-backup-verify.service --since=-2h
```

Keep `--wait`. These units are `Type=exec`, so a plain `start` returns once the container launches:
all three would run at once, and verify would read the repository before the new backup exists.

A full backup ends with `backup command end: completed successfully`. The verify report must say
`status: ok`: verify can exit 0 even when it reports an error, so read the output.

## Change the database image, startup or OS image

Merging such a change only updates the instance template and metadata: database hosts never restart
on apply. Every deploy's `rollout` job then compares each host with its applied configuration:

- a **database host** that differs rolls only during that service's planned downtime; until then the
  deploy warns "rollout pending";
- a **backup repository VM** restarts whenever its `config` label differs from its `running-config`,
  right after its database host when both changed, so pgBackRest stays on one version.

1. Merge the change during a planned downtime of that service, with the `allow-downtime` label
   ([database host changes](deployments.md#database-host-changes)):
   - **Database image:** the service's Renovate release pull request bumps the
     `ghcr.io/…/database:<tag>@<digest>` pin in foundation and in the service root. Deploy verifies
     the image and copies it to Artifact Registry. The hosts pin the digest alone, and the image
     builds reproducibly, so a release without a database change keeps it: nothing changes on the
     hosts and there is nothing to roll. A new digest updates the host templates.
   - **Startup, OS or TLS settings:** edit `environments/production/foundation/terraform.tfvars`
     (`native_backups`, `database_*`) or the service root's `backup_repository`.
2. Take a full backup and verify it (above), before the downtime starts.
3. The deploy rolls the hosts. It snapshots the data disk, then restarts the database host, or
   replaces it when the template changed; either way the data disk and IP are kept. The database is
   down for one to two minutes.
   To roll by hand, for example when a deploy failed after apply:

   ```bash
   gh workflow run roll-database.yaml --repo a-novel/infra -f service=json-keys
   ```

   It restarts both hosts at once, whatever the downtime.

4. If the rollout went wrong, [undo it](#undo-a-rollout) during the same downtime.
5. Clear the downtime once the database answers again.

PostgreSQL **major** upgrades (`PG_MAJOR`) cannot reuse the data directory. They need a
dump-and-restore plan of their own.

## Undo a rollout

Before restarting a database host, the rollout snapshots its data disk as
`agora-data-<service>-<UTC time>`, labelled `role=pre-rollout`, and keeps it 14 days. The deploy
summary names it. The data and WAL share that disk, so PostgreSQL recovers the snapshot as after a
power loss.

1. Revert the pull request and merge it during the downtime. The deploy rolls the host back onto the
   previous configuration. That is enough when the data is intact, for example when the new image
   failed to start.
2. If the data is damaged, put back the disk from the snapshot the faulty rollout took. The revert's
   rollout just snapshotted the damaged disk too, so it stays available for inspection.

   ```bash
   SERVICE=json-keys SNAPSHOT=agora-data-json-keys-<UTC time of the faulty rollout>
   where=(--zone=europe-west1-d --project=a-novel-production-prod)
   group="agora-database-$SERVICE" disk="agora-data-$SERVICE"
   instance="$(gcloud compute instance-groups managed list-instances "$group" "${where[@]}" --format='value(name)')"
   gcloud compute disks describe "$disk" "${where[@]}" --format=json >"$disk.json"
   gcloud compute instance-groups managed stop-instances "$group" --instances="$instance" "${where[@]}"
   gcloud compute instances detach-disk "$instance" --device-name=agora-data "${where[@]}"
   gcloud compute disks delete "$disk" --quiet "${where[@]}"
   gcloud compute disks create "$disk" --source-snapshot="$SNAPSHOT" --type=pd-balanced \
     --size="$(jq -r .sizeGb "$disk.json")GB" --description="$(jq -r .description "$disk.json")" \
     --labels="$(jq -r '.labels | to_entries | map("\(.key)=\(.value)") | join(",")' "$disk.json")" "${where[@]}"
   gcloud compute instances attach-disk "$instance" --disk="$disk" --device-name=agora-data "${where[@]}"
   gcloud compute instance-groups managed start-instances "$group" --instances="$instance" "${where[@]}"
   ```

   - **Merge nothing into infra between the stop and the start.** Stopping lowers the group's target
     size, and a foundation apply would restore it by creating a second host.
   - The new disk keeps the old name, so the group and the host attach it. OpenTofu ignores its
     source snapshot.
   - The swap has not been practised yet
     ([#721](https://github.com/a-novel/infra/issues/721)). Rehearse it on a throwaway group first.

3. Wait until the database answers, then clear the downtime. The template records the data disk's
   ID, so the next foundation change rolls the host once more: it needs a planned downtime, like any
   database host change.

## Capacity

The machine type, container CPU and memory, data disk size and connection limit are foundation
inputs (`database_*` in `variables.tf`). A `check` block keeps 1 GiB of memory and 0.5 vCPU for the
host. Change them by pull request, then roll the host.

Disks can grow but never shrink. A machine-type change replaces the template.
