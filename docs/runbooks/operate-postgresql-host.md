# Operate the private PostgreSQL host

This runbook verifies and maintains the one-member stateful managed instance group that runs the
JSON Keys and Authentication PostgreSQL images. It covers private isolation, capacity, controlled
replacement, disk growth, and rollback.

Every Google Cloud command in this document is for a named human operator. Agents never run
`gcloud` or `tofu apply`.

## Operator context

Load the committed operator defaults before every local command:

```sh
. ./.envrc
./ops/verify-operator-env.sh --github
```

Host discovery, inspection, and SSH are stateless commands documented in
[Debug the private PostgreSQL host](./debug-postgresql-host.md).

## Apply boundary

Merging, validating, or planning this repository creates nothing, and there is no supported local
apply command. Foundation and release changes may be applied only by manually dispatching their
protected workflow from the reviewed `master` commit.

Stop before every mutating step unless all of these controls exist on `master`:

1. the management plane and remote state are applied and verified;
2. the protected foundation and release workflows authenticate through their exact Workload
   Identity Federation providers;
3. each workflow stores its opaque saved plan only in private Google Cloud storage and prints only
   the sanitized action/resource-type summary;
4. the matching GitHub environment requires a reviewer, rejects administrator bypass, and prevents
   self-review unless the bootstrap runbook's solo-maintainer exception is active;
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
disk snapshots are defined in code. They are deployed only by the protected workflows. An empty
cluster may be initialized for verification, but no application may write production data until
the latest logical backups and both independent clean restores pass the
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
- Use a Google account listed in `database_operator_principals`. It needs Compute Viewer, Logs
  Viewer, Monitoring AlertPolicy Viewer, Service Usage Consumer, OS Admin Login, IAP Tunnel
  Resource Accessor limited to port `22`, and Service Account User on the exact database runtime
  identity.
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

## Verify foundation state after apply

```sh
./ops/database-host.sh inspect
```

The command derives the current zone and generated instance, then prints only the state needed to
verify the group, VM, disk, snapshot policy, firewall, alerts, and active operator grants. It must
end with `PASS database host inspection`.

Check these boundaries in its output:

- one `RUNNING` VM with no external address, the database service account, shielded-VM controls,
  stateful `nic0`, and preserved `agora-data`;
- one `READY` balanced disk, the daily seven-day snapshot policy, and a recent automatic snapshot;
- only the reviewed PostgreSQL, IAP SSH, and deny-all egress firewall rules;
- the five database capacity alerts and the critical recovery alert;
- Compute Viewer, Logs Viewer, Monitoring AlertPolicy Viewer, Service Usage Consumer, OS Admin
  Login, port-22 IAP access, and Service Account User for the active operator.

Use the [debug runbook](./debug-postgresql-host.md) for the reusable Ed25519 key, IAP connection,
safe one-line host checks, and reviewed operator access changes.

## Measure capacity

Use Cloud Monitoring for host CPU, guest memory, and guest disk trends. During a private IAP session,
collect a point-in-time container and PostgreSQL view without payload data:

```bash
sudo docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}'
sudo docker exec --user postgres agora-postgres-json-keys psql --no-psqlrc --tuples-only --no-align --username=agora_json_keys --dbname=agora_json_keys --command="SELECT count(*) AS current_connections, current_setting('max_connections') AS max_connections FROM pg_stat_activity;"
sudo docker exec --user postgres agora-postgres-authentication psql --no-psqlrc --tuples-only --no-align --username=agora_authentication --dbname=agora_authentication --command="SELECT count(*) AS current_connections, current_setting('max_connections') AS max_connections FROM pg_stat_activity;"
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

```sh
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
- [`gcloud` wait until stable](https://cloud.google.com/sdk/gcloud/reference/compute/instance-groups/managed/wait-until)
- [Container-Optimized OS disks and filesystems](https://cloud.google.com/container-optimized-os/docs/concepts/disks-and-filesystem)
- [Container-Optimized OS automatic updates](https://cloud.google.com/container-optimized-os/docs/concepts/auto-update)
- [Container-Optimized OS release notes](https://cloud.google.com/container-optimized-os/docs/release-notes)
- [Container-Optimized OS support lifecycle](https://cloud.google.com/container-optimized-os/docs/resources/support-lifecycle)
- [Container-Optimized OS host firewall](https://cloud.google.com/container-optimized-os/docs/how-to/firewall)
- [Docker bridge networking](https://docs.docker.com/engine/network/drivers/bridge/)
- [Docker port publishing](https://docs.docker.com/engine/network/port-publishing/)
- [Docker restart policies](https://docs.docker.com/engine/containers/start-containers-automatically/)
- [OS Login setup](https://cloud.google.com/compute/docs/oslogin/set-up-oslogin)
- [Create SSH keys](https://cloud.google.com/compute/docs/connect/create-ssh-keys)
- [Add SSH keys to OS Login](https://cloud.google.com/compute/docs/connect/add-ssh-keys#os-login)
- [`gcloud` OS Login SSH key update](https://cloud.google.com/sdk/gcloud/reference/compute/os-login/ssh-keys/update)
- [IAP TCP forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding)
- [Cloud Monitoring access control](https://cloud.google.com/monitoring/access-control)
- [Service Usage access control](https://cloud.google.com/service-usage/docs/access-control)
- [Google-managed IAP routes](https://cloud.google.com/vpc/docs/routes#special_return_paths)
- [Persistent Disk resize](https://cloud.google.com/compute/docs/disks/resize-persistent-disk)
- [Production cost worksheet](../costs/production.md)
