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
sudo systemctl start agora-backup-check.service
sudo systemctl start agora-backup-full.service
sudo systemctl start agora-backup-verify.service
sudo journalctl -u agora-backup-full.service -u agora-backup-verify.service --since=-2h
```

A full backup ends with `backup command end: completed successfully`. The verify report must say
`status: ok`: verify can exit 0 even when it reports an error, so read the output.

## Change the database image, startup or OS image

Merging such a change only updates the instance template and metadata, because database hosts never
restart on apply.

1. Merge the change:
   - **Database image:** Renovate's `database images` pull request bumps the
     `ghcr.io/…/database:<tag>@<digest>` pin in foundation and in the service root. Deploy verifies
     the image and copies it to Artifact Registry.
   - **Startup, OS or TLS settings:** edit `environments/production/foundation/terraform.tfvars`
     (`native_backups`, `database_*`) or the service root's `backup_repository`.
2. Take a full backup and verify it (above).
3. In a quiet window, once the deploy finished, roll the hosts:

   ```bash
   gh workflow run roll-database.yaml --repo a-novel/infra -f service=json-keys
   ```

   The run restarts the database host. When the template changed it replaces the host instead;
   either way the data disk and IP are kept. It then restarts the repository VM and checks health.
   The database is down for one to two minutes.

4. If the new image fails to start, revert the pull request, merge, and roll again.

PostgreSQL **major** upgrades (`PG_MAJOR`) cannot reuse the data directory. They need a
dump-and-restore plan of their own.

## Capacity

The machine type, container CPU and memory, data disk size and connection limit are foundation
inputs (`database_*` in `variables.tf`). A `check` block keeps 1 GiB of memory and 0.5 vCPU for the
host. Change them by pull request, then roll the host.

Disks can grow but never shrink. A machine-type change replaces the template.
