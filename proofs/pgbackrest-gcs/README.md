# Private pgBackRest / GCS proof host

**Code only; not provisioned or executed.** This root prepares the next bounded experiment for
[#190](https://github.com/a-novel/infra/issues/190). It does not adopt pgBackRest or change production.
The [offline proof](../pgbackrest/README.md) and [synthetic storage result](../gcs-storage/result-20260927.md)
cover different contracts; neither establishes real database recovery through GCS.

## Ownership and isolation

One empty `e2-medium` COS VM, a 20 GiB SSD boot disk and a separate 10 GiB SSD data disk are sufficient
for the small synthetic experiment. There is no database startup script, image pull, scheduler,
provisioner or automatic backup. Native pgBackRest will perform the later backup/restore operations;
this root only supplies its host and repository. No new library or test framework is needed.

The root composes `../gcs-storage`, preserving that root's resource addresses and policy. Its own
project input requires a **fresh** `a-novel-gcs-proof-pgbr<6–8 digits>` project, excluding the retained
September storage trial. A name guard is not evidence of project ownership. Keep both roots' state
and evidence separate; never initialize this root against the earlier trial's state.

| Resource address                                                            | Purpose and authority                                                                                               | Removal / cost boundary                                                                                                                       |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `module.repository.google_storage_bucket.trial[service/peer]`               | Private, versioned synthetic repositories; bounded unlocked retention, seven-day soft delete, no lifecycle deletion | `force_destroy=false`; inventory all generations and honor every deadline before separately approved cleanup; retained copies remain billable |
| `module.repository.google_service_account.trial[writer/recovery]`           | Distinct writer and recovery principals, no keys                                                                    | Remove temporary operator grants before account cleanup                                                                                       |
| `module.repository.google_project_iam_custom_role.trial[writer/recovery]`   | Writer create/get/list/delete; recovery create/get/list/restore                                                     | Neither can change policy; recovery cannot delete                                                                                             |
| `module.repository.google_storage_bucket_iam_member.trial[writer/recovery]` | Object roles on the selected bucket only                                                                            | No peer or project-level grant; verify inherited IAM live                                                                                     |
| `google_compute_instance.trial`                                             | Writer attached initially; OS Login, Shielded VM, no external IP or database ingress                                | Native STOP after four hours per boot, no automatic restart; deleting the VM deletes only its boot disk                                       |
| `google_compute_disk.data`                                                  | Separately owned SSD, surviving VM deletion                                                                         | Destruction needs explicit review; copy evidence first                                                                                        |
| `google_compute_network.trial`, `google_compute_subnetwork.trial`           | Dedicated regional network, private Google access and flow logs                                                     | No peering or production subnet attachment                                                                                                    |
| `google_compute_router.trial`, `google_compute_router_nat.trial`            | Outbound registry access for this subnet                                                                            | NAT, allocated addresses and logs can incur charges even after the VM stops                                                                   |
| `google_compute_firewall.iap/https/deny_egress`                             | IAP SSH only; outbound TCP 443 then deny other egress                                                               | HTTPS is not a destination allowlist; no database ports are allowed                                                                           |

Firewall rules apply to the isolated network, including after a human-approved writer-to-recovery
identity switch. Only this VM belongs there. Metadata-server access is needed for native instance
credentials; no workstation ADC, service-account key, production secret or mounted operator home
belongs inside a container. There are no human access grants in HCL. Separately approve expiring IAP,
OS Login and exact-account attachment/impersonation rights; do not grant blanket project ownership.

The [native runtime limit](https://docs.cloud.google.com/compute/docs/instances/limit-vm-runtime)
stops compute, not the experiment's bill. Disks, networking, logs and retained objects still need
cleanup. A manual restart begins another bounded run and requires operator intent.

## Before any live operation

Merging this root authorizes none of the following. Obtain separate approval in #190 for:

1. The exact commit, fresh project, billing, enabled APIs (Compute, Storage, IAM, IAM Credentials,
   IAP and OS Login), operator, cleanup owner, cost ceiling, retention and reviewed exact COS image.
2. The selected published service database **SemVer** image. Refresh vulnerability/provenance review;
   resolve findings or explicitly accept the residual risk before exposing even this narrow identity.
   The [offline image findings](../pgbackrest/README.md#packaging-and-security-review) are not waived.
   Resolve the reviewed version once into generated digest evidence; do not use the offline proof image,
   add PG17, run service bootstrap entrypoints or download packages during the live experiment.
3. A saved plan from this root with private durable local state: exactly **17 new resources** (eight
   storage/IAM, seven networking, one VM and one data disk), no import, replacement or deletion.
   Enable APIs before planning. Keep state outside `/tmp` and retain it through final cleanup.
4. The exact native command batch and destructive synthetic-data steps below. HCL validation cannot
   prove quotas, inherited IAM, COS/container metadata access or real restoration behavior.

Provisioning is human-only, using the existing storage trial's saved-plan discipline with this root
and a new state directory. Do not run either production workflow or a backend migration. If a newly
created custom role has not propagated, inspect the exact project/role/bucket relationship, then
review a fresh plan for only the missing bindings; do not broaden permissions.

## Live acceptance sequence (not yet authorized)

Use the selected published database image with native PostgreSQL and pgBackRest commands, a synthetic
database and a new repository prefix. Configure `repo1-type=gcs`, `repo1-gcs-key-type=auto` and the
selected trial bucket. Keep PostgreSQL on a Unix socket, override the service entrypoint, run as its
non-root database user and mount only the trial data/configuration. Native
[GCS authentication and time selection](https://pgbackrest.org/configuration.html) own those mechanics.

| Stage                                | Required observation                                                                                                                                                                                                                                             |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Instance identity and isolation      | Selected repository operations succeed from the attached writer; peer list/create and bucket-policy changes fail for the intended permission, not network/authentication failure                                                                                 |
| Full → differential → WAL            | Record native backup sets/LSNs and a restore point between distinguishable committed rows; `info`, `verify`, exact-set restore and PITR recover the expected rows, role and UUID extension                                                                       |
| Interrupted upload / host loss       | Interrupt a synthetic backup, stop the VM, preserve repository evidence and discard only the approved synthetic data; incomplete work must not replace the prior usable backup selection                                                                         |
| Aged dependency loss                 | After retention, delete only reviewed full/catalog/WAL generations still needed by a newer differential; prove native restore fails before repair, without substituting a newer backup                                                                           |
| Recovery without writer identity     | Stop the host, remove writer authority and separately attach the recovery account; confirm its metadata identity and effective rights after old writer tokens are unusable; no token copied from the writer or workstation                                       |
| Native object recovery and selection | Restore exact soft-deleted dependencies with create-only preconditions. Record new timestamps/generations. Compare the original `--repo=1 --repo-target-time` selection with explicit `--set` recovery and validate the recovered SQL, not just object checksums |
| Finish                               | Stop PostgreSQL/VM, export sanitized evidence, revoke temporary grants, inventory every live/noncurrent/soft-deleted generation and obtain scoped cleanup approval                                                                                               |

Record command, exit status, backup set, cutoff, generation/checksum, database result and elapsed time
for each stage. Start with one service; no blanket claim for the other service's image. A four-hour
compute window is not a recovery-time objective. If an interruption does not actually reach an upload,
repeat only after reviewing the evidence; do not count cancellation alone as a successful fault test.

Recreated bytes may no longer be visible at the original repository time cutoff. **Do not introduce a
second catalog or arbitrary object reconstruction to make the drill pass.** If native selection cannot
recover the accepted historical chain, report the limitation and reject or explicitly narrow the design.
Keep all existing logical backup readers, custody and schedules until a separate adoption decision.

## Validation and cleanup

Existing credential-free CI runs format, backend-disabled init/validate, mock tests and TFLint for this
root. The storage root's tests own bucket/IAM policy; this root tests host/network boundaries and rejects
the previous trial project and floating OS families. No live cloud client runs in tests.

After an approved drill, stop compute promptly and preserve private evidence outside the VM. Review
native generation inventories and exact deletions; honor retention and soft-delete deadlines without
weakening policy. Review a fresh destroy plan for these addresses only, including the separate data
disk. Remove networking promptly when no longer needed rather than leaving NAT active through the
storage window. Reconcile state after any separately reviewed partial teardown. Delete the disposable
project only after retained objects and owned resources are reconciled, then verify final deletion
after Google's recovery window. No scheduled project recreation or cleanup automation is added.
