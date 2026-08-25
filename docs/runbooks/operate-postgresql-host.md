# Operate the private PostgreSQL host

This runbook verifies and maintains the one-member stateful managed instance group that runs the
JSON Keys and Authentication PostgreSQL images. It covers the idle foundation host, first database
activation, private isolation, capacity, controlled replacement, disk growth, and rollback.

Every Google Cloud command in this document is for a named human operator. Agents never run
`gcloud` or `tofu apply`.

## Current stop condition

No protected foundation or release apply workflow exists. Merging, validating, or planning this
repository creates nothing, and there is no supported local apply command.

Stop before every mutating step until all of these controls exist on `master`:

1. the management plane and remote state are applied and verified;
2. the protected foundation and release workflows authenticate through their exact Workload
   Identity Federation providers;
3. each workflow stores its opaque saved plan only in private Google Cloud storage and prints only
   the sanitized action/resource-type summary;
4. the matching GitHub environment requires an independent reviewer and rejects administrator
   bypass;
5. OpenTofu applies only the reviewed, unexpired plan from the merged commit; the database release
   step invokes only the fixed repository helper with reviewed manifest/receipt inputs; both paths
   prove convergence afterward.

The inspection commands below become available after those workflows create the host. They do not
authorize an operator to change a VM, group, disk, firewall, metadata, or secret with `gcloud`.

## Result and operating limits

Foundation creates one always-on, single-zone `e2-medium` VM with no external IP. A stateful
managed instance group preserves its generated name, private address, and 50 GiB balanced data disk.
The 20 GiB COS boot disk is replaceable. The host stays idle while release metadata is absent.

One enabled database release starts both clusters as one unit:

| Cluster        | Private host port | Database and role      | Preserved directory                    |
| -------------- | ----------------: | ---------------------- | -------------------------------------- |
| JSON Keys      |              5432 | `agora_json_keys`      | `/mnt/disks/agora-data/json-keys`      |
| Authentication |              5433 | `agora_authentication` | `/mnt/disks/agora-data/authentication` |

This shape minimizes fixed cost. It is not highly available: a template update, disk-growth reboot,
host failure, or zone outage interrupts both databases. Managed replacement reuses the same disk, so
it does not repair corrupted data. The group therefore has no autoscaler or health-based autohealing
loop.

Four-hour logical backup jobs, monthly clean restore jobs, an hourly recovery monitor, and daily
disk snapshots are defined in code. They are not deployed until the protected workflows exist. An
empty cluster may be initialized for verification, but no application may write production data
until both first logical backups and both independent clean restores pass the
[recovery runbook](./backup-and-restore-postgresql.md).

## Security invariants

- The VM has one internal interface, no access configuration, and no public frontend or DNS record.
- VPC ingress reaches only the database tag, from the production subnet, on TCP `5432` and `5433`.
  Tagged caller egress, separate database credentials, and PostgreSQL roles complete authorization.
- IAP is the only SSH path. OS Login disables project and instance metadata keys.
- Each PostgreSQL container has its own fixed bridge subnet. The host firewall allows established
  replies and rejects every connection initiated by either container, including DNS, the peer
  cluster, host services, metadata, Google APIs, and internet destinations.
- The database runtime identity reads only the four owner/backup password secrets and promoted image repository
  and writes only logs and metrics.
- Password payloads live in root-owned `/run` files. They never enter GitHub, OpenTofu input or
  state, instance metadata, Docker environment configuration, command arguments, serial output, or
  receipts. Healthy containers retain the read-only bind sources for crash restart; failed or
  disabled convergence removes them, and reboot clears the memory-backed directory.
- Release metadata contains only a full Git commit, two promoted Artifact Registry digests, and four
  numeric owner/backup Secret Manager version IDs. Release IAM has no disk, template, network, IAM,
  secret-payload, or direct instance-lifecycle permission. Its sole VM permission is `setMetadata`,
  conditionally fenced to the generated `agora-database-*` member because Google requires it to
  apply the group map. Group-manager update remains coarse enough to affect group lifecycle, so only
  the fixed protected helper may use that identity.

Stop application traffic and investigate before continuing when any invariant fails. Never add a
temporary external IP, public PostgreSQL firewall rule, NAT, proxy, or service-account key for
debugging.

## Prerequisites

- Complete [Provision and verify the workload foundation](./provision-workload-foundation.md).
- Use a Google account listed in `database_operator_principals`. It needs Compute Viewer, OS Admin
  Login, IAP Tunnel Resource Accessor limited to port `22`, and Service Account User on the exact
  database runtime identity.
- An operator from another Google organization also needs OS Login External User from that
  organization's administrator. This manual grant stays outside workload-project automation.
- Keep MFA enabled and work in a private, non-recorded shell with tracing disabled.
- For an enabled release, record the prior private receipt, exact promoted digests, release commit,
  and numeric password versions before approving a change.
- Add password payloads with [Add or rotate a secret version](./secret-versions.md). Keep the two
  owner passwords and two backup passwords pairwise distinct and inside the documented 32–128
  character URL-safe alphabet.
- Keep both database images on the same PostgreSQL major. The current service images use PostgreSQL 18.
- Do not remove or override the host-supplied `agora.database_image` PostgreSQL startup setting. It
  binds each completed logical backup to the server's running immutable digest.
- Before a database image, migration, or host change containing production data, require the
  recovery runbook's fresh scheduled-snapshot and logical-backup gate. Keep the latest monthly clean
  restore evidence within its operating review window.

## Select the exact host

Use a fresh Bash session. These values are identifiers, but project and network details still stay
out of public issues and logs.

```bash
set -euo pipefail
set +x

read -r -p 'Workload project ID: ' WORKLOAD_PROJECT_ID
read -r -p 'Database zone [europe-west1-b]: ' DATABASE_ZONE
read -r -p 'Database operator IAM member (user: or group:): ' DATABASE_OPERATOR_PRINCIPAL
DATABASE_ZONE="${DATABASE_ZONE:-europe-west1-b}"
DATABASE_REGION="${DATABASE_ZONE%-*}"
DATABASE_GROUP='agora-database'
DATABASE_DISK='agora-data'

[[ "$WORKLOAD_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "$DATABASE_ZONE" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]]
[[ "$DATABASE_OPERATOR_PRINCIPAL" =~ ^(user|group):[^[:space:]@]+@[^[:space:]@]+$ ]]

mapfile -t DATABASE_INSTANCES < <(
  gcloud compute instance-groups managed list-instances "$DATABASE_GROUP" \
    --project="$WORKLOAD_PROJECT_ID" \
    --zone="$DATABASE_ZONE" \
    --format='value(instance.basename())'
)
[[ "${#DATABASE_INSTANCES[@]}" -eq 1 ]]
DATABASE_INSTANCE="${DATABASE_INSTANCES[0]}"
[[ "$DATABASE_INSTANCE" =~ ^agora-database-[a-z0-9-]+$ ]]

DATABASE_PRIVATE_IP="$(
  gcloud compute instances describe "$DATABASE_INSTANCE" \
    --project="$WORKLOAD_PROJECT_ID" \
    --zone="$DATABASE_ZONE" \
    --format='value(networkInterfaces[0].networkIP)'
)"
[[ "$DATABASE_PRIVATE_IP" =~ ^10\.20\.0\.[0-9]{1,3}$ ]]

printf 'Group: %s\nInstance: %s\nZone: %s\nPrivate IP: %s\n' \
  "$DATABASE_GROUP" "$DATABASE_INSTANCE" "$DATABASE_ZONE" "$DATABASE_PRIVATE_IP"
```

Expected safe result: exactly one generated instance name and one address inside `10.20.0.0/24`.
Do not proceed if the group has zero or multiple members. Do not print the operator principal.

## Verify foundation state after apply

Describe the stateful group and VM without printing metadata:

```bash
gcloud compute instance-groups managed describe "$DATABASE_GROUP" \
  --project="$WORKLOAD_PROJECT_ID" \
  --zone="$DATABASE_ZONE" \
  --format='yaml(name,targetSize,instanceGroup,updatePolicy,statefulPolicy,status)'

gcloud compute instances describe "$DATABASE_INSTANCE" \
  --project="$WORKLOAD_PROJECT_ID" \
  --zone="$DATABASE_ZONE" \
  --format='yaml(name,status,machineType,networkInterfaces,serviceAccounts,tags.items,shieldedInstanceConfig,disks)'
```

Expected safe result:

- target size is one;
- the update policy is `OPPORTUNISTIC` and uses `RECREATE`, zero surge, and one unavailable instance;
- `agora-data` and `nic0` have a `NEVER` delete rule;
- the VM is `RUNNING`, tagged only `agora-database`, and uses
  `agora-database-host@<project>.iam.gserviceaccount.com`;
- `networkInterfaces[0].accessConfigs` is empty or absent;
- Secure Boot, vTPM, and integrity monitoring are enabled;
- the boot disk and `agora-data` are attached read/write.

Verify the preserved disk:

```bash
gcloud compute disks describe "$DATABASE_DISK" \
  --project="$WORKLOAD_PROJECT_ID" \
  --zone="$DATABASE_ZONE" \
  --format='yaml(name,status,sizeGb,type,physicalBlockSizeBytes,users,labels)'
```

Expected safe result: `READY`, 50 GiB unless reviewed code increased it, `pd-balanced`, 4096-byte
physical blocks, one current user, and database-data labels. A missing user during a controlled
replacement is temporary; otherwise stop.

Verify the code-owned snapshot schedule and attachment:

```bash
gcloud compute resource-policies describe agora-database-daily-snapshots \
  --project="$WORKLOAD_PROJECT_ID" \
  --region="$DATABASE_REGION" \
  --format='yaml(name,region,snapshotSchedulePolicy)'

gcloud compute disks describe "$DATABASE_DISK" \
  --project="$WORKLOAD_PROJECT_ID" \
  --zone="$DATABASE_ZONE" \
  --format='yaml(name,resourcePolicies)'

gcloud compute snapshots list \
  --project="$WORKLOAD_PROJECT_ID" \
  --filter='labels.application=agora AND labels.environment=production AND labels.role=database-snapshot' \
  --sort-by='~creationTimestamp' \
  --limit=1 \
  --format='table(name,autoCreated,status,creationTimestamp,sourceDisk.basename(),storageLocations,labels.role)'
```

Expected safe result: one daily policy at 02:00 UTC, seven-day retention, `KEEP_AUTO_SNAPSHOTS`, EU
storage, an attachment to `agora-data`, and `autoCreated: True`. The final list can be empty only before the first
scheduled 02:00 execution; database activation or any later database change remains blocked until a
matching snapshot is `READY` and no older than six hours.

Verify only the relevant firewall rules:

```bash
for rule in \
  agora-allow-postgres-ingress \
  agora-allow-json-keys-postgres-egress \
  agora-allow-authentication-postgres-egress \
  agora-allow-iap-ssh \
  agora-deny-other-vpc-egress; do
  gcloud compute firewall-rules describe "$rule" \
    --project="$WORKLOAD_PROJECT_ID" \
    --format='yaml(name,direction,priority,sourceRanges,destinationRanges,allowed,denied,targetTags)'
done
```

Expected safe result: database ingress accepts only `10.20.0.0/24` on `5432,5433` and targets
`agora-database`; JSON Keys egress allows only `5432`, Authentication only `5433`, and only the
backup tag appears on both rules. The restore tag has no database allow. IAP SSH accepts only
`35.235.240.0/20` on `22`; the lower-priority fallback denies all remaining egress.

Verify all six alert policies:

```bash
gcloud monitoring policies list \
  --project="$WORKLOAD_PROJECT_ID" \
  --filter='display_name:("Agora database")' \
  --format='table(display_name,enabled,severity,conditions[0].display_name)'

gcloud monitoring policies list \
  --project="$WORKLOAD_PROJECT_ID" \
  --filter='display_name="Agora PostgreSQL recovery job failed"' \
  --format='table(display_name,enabled,severity,conditions[0].display_name)'
```

Expected safe result: CPU above 70%, memory above 70% and 85%, and disk above 70% and 85%, all
enabled, plus one critical failed-recovery-execution policy. Monitoring is not a readiness gate.

Verify the exact operator grants without listing unrelated members:

```bash
DATABASE_SERVICE_ACCOUNT="agora-database-host@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com"

gcloud projects get-iam-policy "$WORKLOAD_PROJECT_ID" \
  --flatten='bindings[].members' \
  --filter="bindings.members=${DATABASE_OPERATOR_PRINCIPAL} AND bindings.role:(roles/compute.osAdminLogin roles/compute.viewer roles/iap.tunnelResourceAccessor)" \
  --format='table(bindings.role,bindings.condition.expression)'

gcloud iam service-accounts get-iam-policy "$DATABASE_SERVICE_ACCOUNT" \
  --project="$WORKLOAD_PROJECT_ID" \
  --flatten='bindings[].members' \
  --filter="bindings.members=${DATABASE_OPERATOR_PRINCIPAL} AND bindings.role=roles/iam.serviceAccountUser" \
  --format='table(bindings.role)'
```

Expected safe result: Compute Viewer and OS Admin Login, IAP Tunnel Resource Accessor with
`destination.port == 22`, and Service Account User on only the database runtime identity. The last
role is required by OS Login because the VM has an attached service account.

## Inspect the host through IAP

Open the privileged debug session:

```bash
gcloud compute ssh "$DATABASE_INSTANCE" \
  --project="$WORKLOAD_PROJECT_ID" \
  --zone="$DATABASE_ZONE" \
  --tunnel-through-iap
```

Do not enable shell tracing, print environment variables, run `docker inspect` without a narrow
`--format`, print files below `/run/agora`, or query the metadata access token.

When the production manifest is disabled, run:

```bash
sudo docker ps --filter 'name=agora-postgres-' \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
sudo findmnt --noheadings --output SOURCE,TARGET,FSTYPE,OPTIONS /mnt/disks/agora-data
sudo df --output=source,size,used,avail,pcent,target /mnt/disks/agora-data
```

Expected safe result: no database container row, and the preserved disk is mounted as EXT4 with
`noatime,nosuid,nodev`. An idle foundation host still incurs its monthly VM and disk cost.

When an approved release is enabled, inspect only non-secret fields:

```bash
sudo docker ps --filter 'name=agora-postgres-' \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}'

for network in agora-database-json-keys agora-database-authentication; do
  sudo docker network inspect "$network" \
    --format '{{.Name}} internal={{.Internal}} subnet={{range .IPAM.Config}}{{.Subnet}}{{end}}'
done

sudo iptables -S AGORA-DATABASE-EGRESS
sudo iptables -S AGORA-DATABASE-HOST

for container in agora-postgres-json-keys agora-postgres-authentication; do
  sudo docker inspect "$container" \
    --format '{{.Name}} running={{.State.Running}} health={{.State.Health.Status}} restart={{.HostConfig.RestartPolicy.Name}} memory={{.HostConfig.Memory}} swap={{.HostConfig.MemorySwap}}'
done
```

Expected safe result:

- exactly two healthy containers, with JSON Keys published on the VM address at `5432` and
  Authentication at `5433`;
- separate non-internal bridges at `172.31.254.0/30` and `172.31.254.4/30`;
- the egress chain returns only established/related traffic from `172.31.254.0/29` and rejects the
  rest;
- the host chain rejects that same source range;
- restart policy is `on-failure` with five retries, and memory-swap equals the memory limit so
  containers do not swap. `on-failure` deliberately does not start containers when Docker boots;
  the metadata startup script restores the deny rules before recreating them.

Prove external name resolution and metadata access fail from both containers:

```bash
for container in agora-postgres-json-keys agora-postgres-authentication; do
  if sudo docker exec "$container" getent hosts example.com >/dev/null 2>&1; then
    printf 'STOP: %s resolved an external name.\n' "$container" >&2
    false
  fi

  if sudo docker exec "$container" \
    timeout 3 bash -c '</dev/tcp/169.254.169.254/80' >/dev/null 2>&1; then
    printf 'STOP: %s reached the metadata address.\n' "$container" >&2
    false
  fi
done
printf 'Database container egress checks were denied.\n'
```

Expected safe result: only the final denial message. Exit the IAP session after inspection.

## Prepare the first database release

The first release is one reviewed unit. Do not enable only one database image.

1. Promote the exact stable SemVer release and `sha256` digest of each service's `database` image
   into the regional `agora-production` repository.
2. Add separate owner and backup password versions for
   `production-json-keys-postgres-password` and
   `production-authentication-postgres-password`, plus
   `production-json-keys-postgres-backup-password` and
   `production-authentication-postgres-backup-password`, through the secret-version runbook. Retain
   only their numeric IDs for release input. The host rejects an out-of-contract or reused value
   before starting either database.
3. Build each DSN in an approved password manager with its matching password and the stateful private
   address:

   | Secret container                         | Required shape                                                                                      |
   | ---------------------------------------- | --------------------------------------------------------------------------------------------------- |
   | `production-json-keys-postgres-dsn`      | `postgres://agora_json_keys:<password>@<private-ip>:5432/agora_json_keys?sslmode=disable`           |
   | `production-authentication-postgres-dsn` | `postgres://agora_authentication:<password>@<private-ip>:5433/agora_authentication?sslmode=disable` |

   Launch deliberately avoids a self-managed PostgreSQL certificate authority. `sslmode=disable` is
   acceptable only while callers and the host stay on private addresses in this Google Cloud VPC:
   [Google's virtual network authenticates, integrity-protects, and encrypts private-IP traffic](https://cloud.google.com/docs/security/encryption-in-transit#google_cloud_virtual_network_authentication_and_encryption),
   while SCRAM authenticates PostgreSQL. Before adding an external, hybrid, or differently trusted
   network path, design PostgreSQL TLS and rotate both DSNs; do not change this flag by itself.

   The password contract is URL-safe, so these forms need no percent encoding. Enter the complete
   DSN twice through the hidden stdin procedure. Never assemble it in a shell argument, `.tfvars`,
   GitHub secret, or environment variable.

4. Update both manifest components in one pull request with complete stable SemVer tags and exact
   digests. Confirm both images remain on PostgreSQL major 18.
5. Enable both release-root recovery contracts with the two promoted database digests and exact
   backup-password versions so the backup/restore jobs exist before database activation.
6. Wait for the first foundation-scheduled `agora-data` snapshot to be `READY` and no older than six
   hours. Google starts the daily 02:00 UTC schedule during the following hour; the first release
   window opens only once that snapshot is ready and closes six hours after its actual creation.
7. Supply the full merged Git commit and all four numeric password versions only through the future
   protected release workflow.

The branch preview must contain no cloud credentials and cannot apply. On `master`, the protected
database step must invoke only `ops/deploy-database-release.sh` with the project, zone, full commit,
two promoted digests, and four positive numeric password versions. The helper validates all nine
arguments and requires the existing all-instances map to contain exactly the seven foundation-seeded
keys. Its shared gate requires the fresh scheduled snapshot and skips logical backup only for this
empty first release. It then patches those values and invokes `update-instances` with both the
minimum and maximum action set to `restart`. An unexpected or missing key fails before mutation. The
helper must not create, replace, resize, or directly reconfigure a VM beyond those seven keys and
that restart, nor
may it mutate a disk, template, address, firewall, IAM binding, secret version, or service-account
key.

The release workflow has not landed, so stop here today. Once it exists, its readiness gate must
prove both container health checks and both approved private client paths before recording success.
No production client starts until both immediate backup jobs and both clean restore jobs in the
recovery runbook also pass.

## Measure capacity

Use Cloud Monitoring for host CPU, guest memory, and guest disk trends. During a private IAP session,
collect a point-in-time container and PostgreSQL view without payload data:

```bash
sudo docker stats --no-stream \
  --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}'

for tuple in \
  'agora-postgres-json-keys agora_json_keys agora_json_keys' \
  'agora-postgres-authentication agora_authentication agora_authentication'; do
  read -r container role database <<<"$tuple"
  sudo docker exec --user postgres "$container" \
    psql --no-psqlrc --tuples-only --no-align \
      --username="$role" \
      --dbname="$database" \
      --command="SELECT count(*) AS current_connections, current_setting('max_connections') AS max_connections FROM pg_stat_activity;"
done

sudo df --output=size,used,avail,pcent,target /mnt/disks/agora-data
```

These commands expose counts and resource use, not queries, roles beyond the fixed service role, or
secret values. Measure startup time from the protected workflow and crash recovery only in a
reviewed maintenance window. Use Compute Engine disk metrics for read/write operation rate,
throughput, and latency.

| Signal              | Review point                                                              | Required response                                                                                                                                                                 |
| ------------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Host CPU            | Above 70% for 10 minutes                                                  | Check queries, jobs, and connection pools. Move from shared-core `e2-medium` to `e2-standard-2` when representative load sustains the threshold or startup/recovery becomes slow. |
| Host memory         | 70% warning, 85% critical                                                 | Compare both container RSS values. Reduce connection pools or per-query memory first; move to `e2-standard-2` before 85% is routine.                                              |
| Data disk           | 70% warning, 85% critical                                                 | Plan backup-backed growth at 70%. At 85%, freeze optional writers and grow before resuming normal work.                                                                           |
| Connections         | 70% of 50 per cluster                                                     | Reduce idle pool sizes and identify leaks. At 85%, protect capacity before raising `database_max_connections`; every extra connection consumes memory.                            |
| Database count      | Before database three                                                     | Move to `e2-standard-2` first and remeasure memory, CPU, and recovery.                                                                                                            |
| Later vertical step | `e2-standard-2` remains above 70% CPU or memory under representative load | Review the cost worksheet and use `e2-standard-4`; do not skip measurement or add another always-on host by default.                                                              |

The two container CPU limits total 1.5 of the VM's two visible vCPUs and leave 0.5 outside their
quotas. `e2-medium` is shared-core and provides one sustained vCPU with opportunistic burst, so the
70% measurement gate matters. The two 1,536 MiB memory limits leave 1 GiB for COS and Docker.

## Update the pinned COS image

Automatic in-place COS updates are disabled so a reviewed boot image and foundation commit remain
reproducible. Renovate cannot safely resolve Google Compute Engine's named-image catalog. During the
regular infrastructure dependency review, a human operator compares the pinned image with the
supported stable milestone:

```bash
gcloud compute images describe-from-family cos-stable \
  --project=cos-cloud \
  --format='yaml(name,status,creationTimestamp,deprecated)'
```

The command is read-only and prints no workload project data. Confirm the proposed milestone remains
supported in Google's COS release notes, then change only the `database_cos_image` default to the
exact returned `projects/cos-cloud/global/images/<name>` path. Never commit a mutable image family.

Treat the resulting template change as the planned outage below: require the backup/restore gate,
review one new template and the protected foundation step's explicit `REPLACE`/`RECREATE` rollout,
preserve `agora-data` and `nic0`, and repeat the host, firewall, container, and private-client checks.
If boot or database verification fails, revert the image-name commit and apply the prior template
through the protected workflow.

## Change CPU, memory, or connection capacity

Treat every machine or container-shape change as a planned outage:

1. Run the fresh scheduled-snapshot and logical-backup gate. Confirm the latest clean restore check
   and record the recovery point and accepted lost-write boundary.
2. Confirm the prior foundation commit, instance template, machine type, container limits, and
   release receipt.
3. Change only reviewed inputs in the foundation root:
   `database_machine_type`, `database_container_cpu`,
   `database_container_memory_mb`, or `database_max_connections`.
4. Review the branch checks. For a machine or template metadata change, the protected plan must
   create one immutable template and update the same one-member group's target while retaining
   `agora-data` and the stateful `nic0` address. After that exact plan applies, the protected
   foundation step must invoke `update-instances` with both minimum and maximum action `REPLACE`
   while the group policy keeps replacement method `RECREATE`; the opportunistic group never rolls
   itself. The repository's
   deliberate destructive-change label is required for the old template and boot VM replacement.
5. Schedule a window for both databases. The shutdown script gives each container up to 60 seconds
   and stops them in parallel.
6. Approve only the saved plan from the merged commit. Verify both health checks, private ports,
   disk mount, firewall chains, and capacity again before ending the window.

If convergence fails, stop application traffic. Revert the capacity commit through a pull request
and apply the previous template through the protected foundation workflow. The group recreates the
boot VM with the same name, private address, and preserved data disk. Do not detach the disk, set the
group template manually, or edit instance metadata with `gcloud`.

## Grow the data disk

Persistent Disk and EXT4 can grow but cannot shrink:

1. Run the fresh scheduled-snapshot and logical-backup gate and require a current clean restore
   check.
2. Measure current use and choose the next 10 GiB step. Keep the value from 50 through 1,000 GiB.
3. Increase only `database_data_disk_size_gb` in a foundation pull request.
4. Review the protected plan. The existing disk size must update in place. The size is also recorded
   in immutable template metadata, so the plan creates a new template and replaces only the boot VM.
   Reject any plan that replaces, deletes, detaches, or changes the type of `agora-data`.
5. Approve the maintenance outage. On boot, the startup script mounts the same EXT4 filesystem and
   runs online `resize2fs`.
6. Verify the declared block size and mounted filesystem size with the disk describe and `df`
   commands above, then verify both databases.

A lower configured size must fail planning or provider validation. Never try to force it, edit state,
or recreate the disk.

A disk-type change is a separate migration, not an in-place edit. Its design must create a named
snapshot after quiescing both databases, create a new disk from that snapshot in the same zone,
attach it through reviewed foundation state, verify both clusters, and retain the source disk until
the rollback window closes. The current root deliberately hardcodes `pd-balanced` and blocks disk
replacement, so that migration needs its own reviewed code and runbook before execution.

## Roll back a database release

A release rollback changes container configuration, not data:

1. Freeze new application deployment and retain the failed receipt and non-secret health evidence.
2. Identify the last healthy release commit, both promoted digests, and all four numeric owner/backup
   password versions from its private receipt.
3. Confirm the old and new images share PostgreSQL major 18. A major-version rollback requires a data
   migration or restore design and cannot use this procedure.
4. Revert the manifest through a pull request and supply the prior release commit and all password
   versions to the protected release workflow. Its pre-change gate creates a fresh recovery point
   before rollback.
5. Review one seven-key all-instances metadata update followed by `update-instances` with `RESTART`
   as both the minimum and most disruptive action. It must contain no foundation resource action.
6. Approve the short outage, then repeat the host, container, and private-client checks.

The startup script stops both containers when either image, secret, disk, or health convergence
fails. Reapplying the previous metadata also reactivates the previous password values through the
local socket. Backward-compatible migrations remain; the rollback does not change schema or restore
data.

## Partial-failure recovery

### The host is running but idle unexpectedly

Check whether both manifest components are enabled and whether the protected release receipt exists.
Do not add metadata manually. A missing release is repaired by the protected release workflow; an
intentional disabled manifest correctly leaves the host idle.

### The data disk is absent or refuses to mount

Stop all application writers. Do not format, fsck, detach, or replace it. The startup script formats
only a signature-free disk whose first MiB is entirely zero and refuses every unknown non-empty
device. Inspect the group and disk control plane, preserve logs, and recover through a reviewed
foundation plan or data-restore procedure.

### One database is unhealthy

The boot failure handler stops both containers to avoid a partial release. Preserve only
non-sensitive container status and recent error categories; never paste environment or unrestricted
inspect output. Restore the prior release metadata when the images or password versions caused the
failure. Use data restore only when storage or data is damaged.

### The VM replacement failed

Keep the stateful group and disk. Revert the foundation commit and apply the prior immutable template
through the protected workflow. Never delete the group or disk to retry.

### A password rollout broke clients

Reapply the prior database password versions and prior DSN versions as one coordinated rollback.
Disable the failed new versions only after all consumers are healthy on the prior values. Delayed
destruction follows the secret-version runbook.

### A public path or container egress appears

Freeze application traffic and every infrastructure writer. Identify the change from the reviewed
plan and Cloud Audit Logs. Reconcile it through code with the destructive-change gate when required.
Do not rely on application passwords while a public path exists.

## References

- [Stateful managed instance groups](https://cloud.google.com/compute/docs/instance-groups/configuring-stateful-migs)
- [Stateful disks](https://cloud.google.com/compute/docs/instance-groups/configuring-stateful-disks-in-migs)
- [Stateful internal IP addresses](https://cloud.google.com/compute/docs/instance-groups/configuring-stateful-ip-addresses)
- [Preserved state during updates](https://cloud.google.com/compute/docs/instance-groups/preserved-state)
- [All-instances configuration](https://cloud.google.com/compute/docs/instance-groups/set-mig-aic)
- [MIG update policy types](https://cloud.google.com/compute/docs/instance-groups/rolling-out-updates-to-managed-instance-groups#configure_update_policy)
- [`gcloud` all-instances update](https://cloud.google.com/sdk/gcloud/reference/compute/instance-groups/managed/all-instances-config/update)
- [`gcloud` update instances](https://cloud.google.com/sdk/gcloud/reference/compute/instance-groups/managed/update-instances)
- [Container-Optimized OS disks and filesystems](https://cloud.google.com/container-optimized-os/docs/concepts/disks-and-filesystem)
- [Container-Optimized OS automatic updates](https://cloud.google.com/container-optimized-os/docs/concepts/auto-update)
- [Container-Optimized OS release notes](https://cloud.google.com/container-optimized-os/docs/release-notes)
- [Container-Optimized OS support lifecycle](https://cloud.google.com/container-optimized-os/docs/resources/support-lifecycle)
- [Container-Optimized OS host firewall](https://cloud.google.com/container-optimized-os/docs/how-to/firewall)
- [Docker bridge networking](https://docs.docker.com/engine/network/drivers/bridge/)
- [Docker port publishing](https://docs.docker.com/engine/network/port-publishing/)
- [Docker restart policies](https://docs.docker.com/engine/containers/start-containers-automatically/)
- [OS Login setup](https://cloud.google.com/compute/docs/oslogin/set-up-oslogin)
- [IAP TCP forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding)
- [Google-managed IAP routes](https://cloud.google.com/vpc/docs/routes#special_return_paths)
- [Persistent Disk resize](https://cloud.google.com/compute/docs/disks/resize-persistent-disk)
- [Production cost worksheet](../costs/production.md)
