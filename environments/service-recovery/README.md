# Disposable native recovery — inactive

This root prepares one isolated JSON Keys host for an exact full/differential pgBackRest restore.
`recovery = null` creates nothing. A configured host is stopped, has no startup restore, and stops
after four hours when explicitly started. The worker restores files to backup consistency and leaves
PostgreSQL stopped. It does not prove SQL recovery or authorize traffic cutover.

The protected recovery workflow enrolls **host preparation only**, disabled unless
`NATIVE_RECOVERY_PREPARATION_ENABLED=true`. Assessment and drift inspect registered state without
that mutation flag. Do not apply this root directly; see [preparation](#guarded-host-preparation)
and the separate [activation gates](#activation-gates). Legacy logical recovery and current backups
remain unchanged.

The prepared image consumes the published Wolfi database patch. Its blocking image scan is unchanged;
green scans and offline proofs do not authorize publication, provisioning or recovery execution.
This is a fresh-database boundary, not an in-place upgrade of Debian data directories. Retain the
old image/reader for existing backups and review compatibility against the selected backup evidence.

## Contract

Protected registration supplies the complete `protected_projects` set, original service project and
management project/number. The approved recovery request selects an independently evidenced PostgreSQL
system ID, exact completed set and optional repository-time cutoff. It must not learn the expected
system ID from the catalog it is about to check. The current pilot is PostgreSQL 18, JSON Keys only,
with an explicit `immediate` target (the selected backup's consistency point).

`restore_image` is the provenanced `native-restore` image promoted into the disposable project's
`agora-tooling` repository, selected by its generated immutable digest. Its maintained Dockerfile uses
the service database's SemVer tag. Review the resolved base, PostgreSQL version and extensions with the
backup evidence; a matching major alone does not prove application compatibility.

The worker checks its attached management-owned recovery identity and disposable project. Before
calling native tools it creates `/recovery/attempt` exclusively. It records the approved request,
native catalog and diagnostics there, verifies the selected catalog entry's database epoch and system
ID, and invokes pgBackRest with an exact set and no delta/force fallback. After restore it checks
`pg_controldata` against that same system ID. `files-restored.json` means only that files were restored;
neither the source nor restored PostgreSQL was started by the worker.

Any existing attempt or container name blocks replay, including after interruption. Preserve failed
attempts. A new attempt requires reconciliation and separately approved fresh destination storage.
`repo-target-time` is preserved for both catalog reads and restore. Soft-delete repair can make an
object visible only under a newer generation: changing that cutoff is a new selection, not a retry.

## Guarded host preparation

Protected `FOUNDATION_TFVARS_JSON` registers `service_recovery_projects` as a map from disposable
project ID to `json-keys`. It creates no project or grant. `NATIVE_RECOVERY_TFVARS_JSON` maps each
destination to this root's complete `{ "state_bucket": "…", "recovery": { … } }` input. The nested
fields are defined in [variables.tf](variables.tf); include management, legacy workload and every
registered service project in `protected_projects`. Unknown fields, unregistered destinations,
peer sources, implicit backup selection and mismatched backend coordinates fail before authentication.
Digest validation checks the image's exact destination and syntax, **not its provenance**; reviewed
publication/promotion and backup compatibility remain prerequisites.

After separate activation approval, dispatch from clean, current `master`:

```text
go run ./cmd/infra recovery plan-native <registered-destination>
go run ./cmd/infra recovery apply-native <registered-destination> <plan-run-id-attempt>
```

Both runs require `production-recovery` review and retain global infrastructure serialization.
The private plan expires after 24 hours and binds the exact commit, destination and input bytes.
Preparation accepts only creates/no-ops in the disposable project, with the VM's desired state
`TERMINATED`; updates, replacements, imports and cleanup require a separate maintenance path.

State and converged inputs use `foundation/recovery/services/DESTINATION/`; private plans use
`foundation/plans/recovery/services/DESTINATION/`. These reuse the existing recovery storage boundary.
Apply acquires the **source service's** guard before consuming the plan, then verifies zero-change
convergence and publishes `host-prepared` completion under that source's receipt folder before
releasing the exact guard generation. This records host preparation, not database recovery or health.
Uncertain apply, publication or acknowledgement retains the guard; use the existing
[operation inspector and finisher](../../docs/service-operations.md#inspect-an-interrupted-apply).
Neither planning nor successful preparation starts the restore unit, formats storage or cuts over traffic.

## Resources and cost boundary

Every address below is conditional on `recovery`. The root grants no IAM roles, enables no account,
creates no project, formats no disk, and provisions no scheduler, snapshot, NAT or public IP.

| Address                                                                   | Purpose, authority and lifecycle                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `google_compute_instance.recovery`                                        | One stopped `e2-medium` COS host with IAP/OS Login, recovery identity and a four-hour STOP cap. Its 20 GiB standard boot disk is auto-deleted with the VM. [Provider](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/compute_instance), [runtime limit](https://cloud.google.com/compute/docs/instances/limit-vm-runtime).                                                                                                          |
| `google_compute_disk.data`                                                | Separately owned 10–100 GiB SSD, sized for restored data/WAL and evidence. Deleting the VM preserves it; deleting this resource loses the local attempt. Export evidence and obtain exact cleanup approval first. [Provider](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/compute_disk), [disk lifecycle](https://cloud.google.com/compute/docs/disks/modify-persistent-disk).                                                    |
| `google_compute_network.recovery`, `google_compute_subnetwork.recovery`   | Dedicated IPv4 network/subnet; no shared VPC, peering or production routes. The default internet route is removed. [Network provider](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/compute_network), [subnet provider](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/compute_subnetwork), [VPC](https://cloud.google.com/vpc/docs/vpc).                                                           |
| `google_compute_route.google_apis`                                        | Private Google Access route to the restricted Google API VIP only. [Provider](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/compute_route), [routing requirements](https://cloud.google.com/vpc/docs/configure-private-google-access).                                                                                                                                                                                             |
| `google_compute_firewall.recovery`, `google_compute_firewall.deny_egress` | IAP SSH ingress, Google VIP HTTPS egress and deny-all egress fallback. No PostgreSQL ingress. Metadata is still reachable by the trusted restore worker; these rules do not restrict its API permissions. [Provider](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/compute_firewall), [firewall behavior](https://cloud.google.com/firewall/docs/firewalls).                                                                       |
| `google_dns_managed_zone.apis`, `google_dns_record_set.apis`              | Network-private Google API and Artifact Registry resolution to the restricted VIP. Deleting them removes this host's API route-by-name. [Zone provider](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/dns_managed_zone), [record provider](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/dns_record_set), [private access DNS](https://cloud.google.com/vpc/docs/configure-private-google-access). |

There is no recurring allocation by default. After provisioning, stopped VMs still incur disk and
DNS charges; retained backup generations, requests and transfers also count. The runtime cap limits
one start, not monthly spend or disk retention. Approve a priced, sized attempt and a cleanup deadline
before provisioning. This is not an additional permanent backup VM.

## Activation gates

1. Review the protected registration and private inputs, then separately authorize host preparation.
   The workflow is implemented but disabled. Execution, SQL recovery and cutover are not enrolled;
   each needs its own guarded outcome before it may run. Never release ambiguous work.
2. Separately approve image publication/promotion and effective IAM. The existing management recovery
   account stays disabled until approved. Cross-project attachment, organization policy, IAP/OS Login,
   exact native-bucket access, Artifact Registry reads, source guard and completion-folder access
   need explicit review. This enrollment adds no IAM grants. Do not attach the
   writer or widen its grants. Private Google Access is not a service perimeter or an IAM grant.
3. Review a fresh empty disposable project, source ownership, independent database identity/major,
   selected native label, retained image and any repository cutoff. Record lost writes and source
   fencing requirements; inspect/quiesce native work before disruptive or repository-mutating steps.
4. Apply only an approved saved plan. Verify the stopped host, effective network/IAM, image and disk
   IDs. Format only the independently verified fresh data disk and mount it at
   `/mnt/disks/agora-recovery` with `nodev,nosuid,noexec`. No formatter is embedded in boot or restore.
5. Under a separately admitted execution, start the host and the single disabled unit explicitly.
   Capture the local outcome and native diagnostics privately. A lost runner response is unknown
   outcome; inspect the retained container/attempt rather than starting again.
6. Approve SQL recovery separately. Restore-generated configuration includes an archive reader; do
   not boot recovered configuration with cloud authority by default. Establish an isolated WAL-fetch
   and SQL-validation boundary, verify roles/extensions/data, and prove source-host-loss recovery.
   Cutover additionally requires application compatibility, source fencing and lost-write acceptance.
7. Export evidence and publish the reviewed outcome through existing private custody. Stop the VM,
   revoke temporary access, then review a cleanup plan for only this disposable project's resources.
   Keep original backup objects, historical logical readers and retained receipts intact.

Offline tests exercise real pgBackRest restoration and the worker's policy, with local synthetic
storage replacing GCS. Mocked provider tests establish the prepared graph. Neither proves effective
cloud IAM/DNS, notification delivery, recovery timing, capacity or source-loss recovery.

References: [pgBackRest restore](https://pgbackrest.org/command.html#command-restore),
[GCS recovery trial](../../proofs/pgbackrest-gcs/result-20260927.md),
[service admission](../../docs/service-operations.md),
[image publication](../../docs/runbooks/publish-rollout-verifier.md).
