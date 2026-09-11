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

Foundation creates one private `e2-medium` VM per database. Each has its own single-member
stateful group, private address, runtime identity, and 50 GiB `pd-balanced` data disk.
The replaceable 20 GiB COS boot disk also uses SSD-backed `pd-balanced` storage. Each host
stays idle until its own release metadata is configured.

Each host starts only its own PostgreSQL container:

| Cluster        | Private host port | Database and role      | Preserved directory                    |
| -------------- | ----------------: | ---------------------- | -------------------------------------- |
| JSON Keys      |              5432 | `agora_json_keys`      | `/mnt/disks/agora-data/json-keys`      |
| Authentication |              5433 | `agora_authentication` | `/mnt/disks/agora-data/authentication` |

Each database remains single-zone and is not highly available: its template update, disk-growth
reboot, or host failure interrupts that database. A zone outage can interrupt both databases. Managed replacement reuses the same disk, so
it does not repair corrupted data. The group therefore has no autoscaler or health-based autohealing
loop.

Four-hour logical backup jobs, monthly clean restore jobs, an hourly recovery monitor, and daily
disk snapshots are defined in code. They are deployed only by the protected workflows. An empty
cluster may be initialized for verification, but no application may write production data until
the latest logical backups and both independent clean restores pass the
[recovery runbook](./backup-and-restore-postgresql.md).

## Security invariants

- The VM has one internal interface, no access configuration, and no public frontend or DNS record.
- VPC ingress reaches only the database tag, from the production subnet, on that database’s TCP port (`5432` or `5433`).
  Tagged caller egress, separate database credentials, and PostgreSQL roles complete authorization.
- IAP is the only SSH path. OS Login disables project and instance metadata keys.
- Each PostgreSQL container has its own fixed bridge subnet. The host firewall allows established
  replies and rejects every connection initiated by either container, including DNS, the peer
  cluster, host services, metadata, Google APIs, and internet destinations.
- The database runtime identity reads only its two owner/backup password secrets and promoted image repository
  and writes only logs and metrics.
- Password payloads live in root-owned `/run` files. They never enter GitHub, OpenTofu input or
  state, instance metadata, Docker environment configuration, command arguments, serial output, or
  receipts. Healthy containers retain the read-only bind sources for crash restart; failed or
  disabled convergence removes them, and reboot clears the memory-backed directory.
- Release metadata contains only a full Git commit, one promoted Artifact Registry digest, and two
  numeric owner/backup Secret Manager version IDs. Compute reauthorizes the full member
  specification when the protected helper patches that map. Release IAM therefore grants coarse
  group update at project scope, VM and boot-disk prerequisites only for `agora-database-*`,
  data-disk read/attachment only on the two named service disks, template reads only on the exact template, Network User
  only on the production subnet, and the stateful internal-address operations that Compute checks
  at project scope. It cannot mutate snapshots or external addresses and has no secret-payload, IAM,
  VM/disk delete, start, or stop permission. Only the fixed protected helper may use the coarse group
  update.

Stop application traffic and investigate before continuing when any invariant fails. Never add a
temporary external IP, public PostgreSQL firewall rule, NAT, proxy, or service-account key for
debugging.

## Prerequisites

- Complete [Provision and verify the workload foundation](./provision-workload-foundation.md).
- Use a Google account covered by `database_operator_principals`, directly or through a listed
  group. It needs Compute Viewer, Logs Viewer, Monitoring AlertPolicy Viewer, Service Usage
  Consumer, OS Admin Login, IAP Tunnel Resource Accessor limited to port `22`, and Service Account
  User on the exact database runtime identity.
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
./ops/database-host.sh inspect authentication
./ops/database-host.sh inspect json-keys
```

The command derives the current zone and generated instance, then prints the group, VM, disk,
snapshot policy, firewall rules, and alerts. It must end with `PASS database host inspection`. The
final foundation audit is the authoritative IAM check.

Check these boundaries in its output:

- one `RUNNING` VM with no external address, the database service account, shielded-VM controls,
  stateful `nic0`, and preserved service data disk;
- one `READY` balanced disk, the daily seven-day snapshot policy, and a recent automatic snapshot;
- only the reviewed PostgreSQL, IAP SSH, and deny-all egress firewall rules;
- the five database capacity alerts and the critical recovery alert.

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
| Host memory         | 70% warning, 85% critical                                                 | Compare the selected container's RSS with its host memory. Reduce connection pools or per-query memory first; move to `e2-standard-2` before 85% is routine.                      |
| Data disk           | 70% warning, 85% critical                                                 | Plan backup-backed growth at 70%. At 85%, freeze optional writers and grow before resuming normal work.                                                                           |
| Connections         | 70% of 50 per cluster                                                     | Reduce idle pool sizes and identify leaks. At 85%, protect capacity before raising `database_max_connections`; every extra connection consumes memory.                            |
| Database count      | Before database three                                                     | Add a separately sized service-owned VM/disk and review regional CPU quota.                                                                                                       |
| Later vertical step | `e2-standard-2` remains above 70% CPU or memory under representative load | Review the cost worksheet and use `e2-standard-4`; do not skip measurement; shared sizing inputs currently affect both database hosts.                                            |

Each container is limited to 0.75 of its host's two visible vCPUs. `e2-medium` is shared-core and provides one sustained vCPU with opportunistic burst, so the
70% measurement gate matters. Each 1,536 MiB container limit leaves 2.5 GiB for COS, Docker, and filesystem cache.

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
review the new templates and a separately reviewed, bounded replacement step. The existing
foundation workflow applies template targets but does not roll the opportunistic groups. Do not
apply a template-changing maintenance plan until its protected replacement step is implemented
and reviewed. Preserve each service data disk and `nic0`, then repeat all host and client checks.

## Change CPU, memory, or connection capacity

Treat every machine or container-shape change as a planned outage:

1. Run the fresh scheduled-snapshot and logical-backup gate. Confirm the latest clean restore check
   and record the recovery point and accepted lost-write boundary.
2. Confirm the prior foundation commit, instance template, machine type, container limits, and
   release receipt.
3. Change only reviewed inputs in the foundation root:
   `database_machine_type`, `database_container_cpu`,
   `database_container_memory_mb`, or `database_max_connections`.
4. These sizing inputs currently apply to both hosts. Review two new immutable templates, the
   same singleton groups, and preservation of each data disk and stateful `nic0` address.
5. The groups are opportunistic: applying new templates does not replace their running members.
   Stop here unless the maintenance PR also supplies a reviewed protected replacement step,
   bounded to each exact group with `REPLACE`/`RECREATE`. Routine releases permit only restarts.
   Include the deletion label before merge when the plan requires it.
6. Schedule downtime for the affected databases. Each VM stops its own container with a
   60-second grace period. Verify disk mounts, firewall rules, health, and client connections after
   the protected replacement before ending the window.

If convergence fails, retain both disks and restore the previous template through the same reviewed
maintenance procedure. Never delete a group or data disk to retry. A template-target apply alone is
not evidence that a running VM adopted that template.

## Grow the data disk

Persistent Disk and EXT4 can grow but cannot shrink:

1. Run the fresh scheduled-snapshot and logical-backup gate and require a current clean restore
   check.
2. Measure current use and choose the next 10 GiB step. Keep the value from 50 through 1,000 GiB.
3. Increase `database_data_disk_size_gb` in a foundation pull request; this currently grows both disks.
4. Review the protected plan. The existing disk size must update in place. The size is also recorded
   in immutable template metadata, so the plan changes both template targets. Follow the protected replacement prerequisite above;
   the foundation apply alone does not restart or replace the boot VMs.
   Reject any plan that replaces, deletes, detaches, or changes the type of the service data disk.
5. Approve the maintenance outage. On boot, the startup script mounts the same EXT4 filesystem and
   runs online `resize2fs`.
6. Verify the declared block size and mounted filesystem size with the disk describe and `df`
   commands above, then verify both databases.

A lower configured size must fail planning or provider validation. Never try to force it, edit state,
or recreate the disk.

A disk-type change is a separate migration, not an in-place edit. Its design must create a named
snapshot after quiescing the affected database, create a new disk from that snapshot in the same zone,
attach it through reviewed foundation state, verify that cluster, and retain the source disk until
the rollback window closes. The current root deliberately hardcodes `pd-balanced` and blocks disk
replacement, so that migration needs its own reviewed code and runbook before execution.

## Roll back a database release

A release rollback changes container configuration, not data:

1. Freeze new application deployment and retain the failed receipt and non-secret health evidence.
2. Identify the last healthy release commit, the selected service's promoted digest, and its two numeric owner/backup
   password versions from its private receipt.
3. Confirm the old and new images share PostgreSQL major 18. A major-version rollback requires a data
   migration or restore design and cannot use this procedure.
4. Revert the manifest through a pull request and supply the prior release commit and all password
   versions to the protected release workflow. Its pre-change gate creates a fresh recovery point
   before rollback.
5. Review one four-key all-instances metadata update per changed database followed by `update-instances` with `RESTART`
   as both the minimum and most disruptive action. It must contain no foundation resource action.
6. Approve the short outage, then repeat the host, container, and private-client checks.

A host's startup script stops its own container if its image, secret, disk, or health convergence
fails. It cannot stop the other host's container. Reapplying the previous metadata also reactivates the previous password values through the
local socket. Backward-compatible migrations remain; the rollback does not change schema or restore
data.

## Partial-failure recovery

### The host is running but idle unexpectedly

Check whether the selected manifest component is enabled and whether the protected release receipt exists.
Do not add metadata manually. A missing release is repaired by the protected release workflow; an
intentional disabled manifest correctly leaves the host idle.

### The data disk is absent or refuses to mount

Stop all application writers. Do not format, fsck, detach, or replace it. The startup script formats
only a signature-free disk whose first MiB is entirely zero and refuses every unknown non-empty
device. Inspect the group and disk control plane, preserve logs, and recover through a reviewed
foundation plan or data-restore procedure.

### One database is unhealthy

The boot failure handler stops only the affected host's container. Preserve only
non-sensitive container status and recent error categories; never paste environment or unrestricted
inspect output. Restore the prior release metadata when the images or password versions caused the
failure. Use data restore only when storage or data is damaged.

### The VM replacement failed

Keep the stateful group and disk. Revert the foundation commit and apply the prior immutable template
through the protected workflow. Never delete the group or disk to retry.

### A password rollout broke clients

Reapply the prior password versions for the selected database and its clients as one coordinated
rollback. DSNs are derived from the host, port, username, and password; there is no DSN secret.
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
- [IAP TCP forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding)
- [Cloud Monitoring access control](https://cloud.google.com/monitoring/access-control)
- [Service Usage access control](https://cloud.google.com/service-usage/docs/access-control)
- [Google-managed IAP routes](https://cloud.google.com/vpc/docs/routes#special_return_paths)
- [Persistent Disk resize](https://cloud.google.com/compute/docs/disks/resize-persistent-disk)
- [Production cost worksheet](../costs/production.md)
