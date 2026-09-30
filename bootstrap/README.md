# Bootstrap root

This root owns the stable management and recovery plane that later automation uses to manage and
rebuild production. It changes rarely and deliberately outlives the replaceable workload project.
It does not deploy networks, databases, application services, jobs, or revisions.

The management project and empty state bucket form the manual root of trust. The
[bootstrap runbook](../docs/runbooks/bootstrap-management-plane.md) creates the bucket with private
access, versioning, and soft delete before OpenTofu writes state, then imports it into this root.
OpenTofu manages every later bucket change.

## Deployment status

The configuration is ready to create the management plane, but merging it does not create anything.
The initial application is an operator-only procedure performed from `master` after explicit
approval. Agents never run Google Cloud commands or `tofu apply`. Pull requests continue to use a
mocked provider, a disabled backend, and no cloud credentials.

The first plan and apply use the versioned GCS backend. Protected workflows then use keyless
federation and exact private saved plans. The workflow filename, `master` ref, repository numeric
identity, and protected-environment claim are all part of the provider condition; changing any one
is a reviewed trust migration.

## Resource inventory

The provider is pinned in [`versions.tf`](./versions.tf). The links below describe the Google-specific
behavior a maintainer must understand; ordinary OpenTofu language behavior is not repeated.

| OpenTofu address                                                                                   | Agora purpose and boundary                                                                                                                                                                                                                                                                                                                               | Lifecycle, recovery, and cost                                                                                                                                                                                                                                                                                                                                                                     | References                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| -------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `data.google_project.management`                                                                   | Resolves the immutable numeric management-project ID used in bucket names and Workload Identity Federation principals. It does not manage the project.                                                                                                                                                                                                   | Read-only and free. The project ID and billing attachment remain manual bootstrap inputs.                                                                                                                                                                                                                                                                                                         | [Provider data source](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/data-sources/project), [project identifiers](https://cloud.google.com/resource-manager/docs/creating-managing-projects#identifying_projects)                                                                                                                                                                                                                           |
| `google_project_service.management`                                                                | Keeps management APIs enabled for storage, IAM, federation, secrets, logging, billing, quota administration, organization policies and platform visual evidence in Drive.                                                                                                                                                                                | APIs are not disabled on destroy, preventing a configuration removal from breaking recovery. Enabling these APIs has no direct recurring charge.                                                                                                                                                                                                                                                  | [Provider resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_project_service), [enabling services](https://cloud.google.com/service-usage/docs/enable-disable)                                                                                                                                                                                                                                                        |
| `google_storage_bucket.state`                                                                      | Private EU multi-region backend for the `bootstrap`, `foundation`, and `release` state objects and their `.tflock` objects.                                                                                                                                                                                                                              | Public access prevention, uniform access, versioning, seven-day soft delete, `prevent_destroy`, and `force_destroy = false` protect it. A lifecycle rule removes a noncurrent generation only after it is at least 90 days old and 50 newer generations exist. Google-managed encryption is the deliberate low-cost default. Storage bytes, operations, and recovery reads are billable.          | [Provider resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/storage_bucket), [backend locking](https://opentofu.org/docs/language/settings/backends/gcs/), [Object Versioning](https://cloud.google.com/storage/docs/object-versioning), [soft delete](https://cloud.google.com/storage/docs/soft-delete), [default encryption](https://cloud.google.com/storage/docs/encryption/default-keys)                              |
| `google_storage_managed_folder.state` and `.recovery_state`                                        | Create normal `bootstrap/`, `foundation/`, and `release/` boundaries plus four exact nested recovery state/plan boundaries. Recovery can write only `foundation/{recovery,plans/recovery}/` and `release/{recovery,plans/recovery}/`; it cannot overwrite bootstrap or normal production state.                                                          | Every folder prevents deletion and refuses to destroy contained objects. Managed folders add no running service or fixed monthly charge.                                                                                                                                                                                                                                                          | [Provider resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/storage_managed_folder), [managed folders](https://cloud.google.com/storage/docs/managed-folders)                                                                                                                                                                                                                                                               |
| `google_storage_bucket.backups`                                                                    | Durable EU destination for encrypted PostgreSQL logical backups. It remains in the management project if the workload project is lost.                                                                                                                                                                                                                   | Public access prevention, uniform access, `prevent_destroy`, and `force_destroy = false` apply. Objects cannot be removed for seven days and lifecycle deletes them after 14 days. Soft delete is disabled to avoid a second billable retention copy. The retention policy remains unlocked only until both first clean restores succeed; locking it is an explicit irreversible reviewed change. | [Provider resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/storage_bucket), [Bucket Lock](https://cloud.google.com/storage/docs/bucket-lock), [lifecycle management](https://cloud.google.com/storage/docs/lifecycle), [soft delete](https://cloud.google.com/storage/docs/soft-delete)                                                                                                                                    |
| `google_storage_bucket.receipts` and `google_storage_managed_folder.receipt`                       | EU store for deployment, rollback, initialization, and recovery evidence without putting opaque plans or state in GitHub artifacts. Managed folders make `production/`, `production/success/`, and `recovery/` independent IAM boundaries.                                                                                                               | Versioning, seven-day soft delete, public access prevention, `prevent_destroy`, and `force_destroy = false` apply. Noncurrent receipts are removed only when at least 365 days old and 20 newer versions exist. Release can use only `production/`; recovery reads only successful production receipts and creates only `recovery/` evidence.                                                     | [Provider bucket resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/storage_bucket), [Provider managed-folder resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/storage_managed_folder), [managed folders](https://cloud.google.com/storage/docs/managed-folders), [Cloud Storage data protection](https://cloud.google.com/storage/docs/data-protection)                             |
| `google_service_account.automation`                                                                | Four keyless identities isolate plan/drift, foundational changes, routine releases, and recovery.                                                                                                                                                                                                                                                        | Service-account deletion is blocked. No `google_service_account_key` resource exists; short-lived Google tokens are obtained only through the matching WIF provider. Service accounts have no fixed charge.                                                                                                                                                                                       | [Provider resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_service_account), [service-account practices](https://cloud.google.com/iam/docs/best-practices-service-accounts)                                                                                                                                                                                                                                         |
| `google_iam_workload_identity_pool.github` and `google_iam_workload_identity_pool_provider.github` | One pool contains four providers, each restricted to immutable GitHub organization/repository IDs, `master`, one exact workflow path, and—except read-only planning—one exact protected environment. Each provider maps an unforgeable constant boundary used by only its matching service account.                                                      | Pool and provider deletion are blocked. The OIDC audience is omitted intentionally so Google requires its canonical provider-resource audience. Federation has no service-account key to leak or rotate and no fixed charge.                                                                                                                                                                      | [Pool provider resources](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/iam_workload_identity_pool_provider), [deployment-pipeline federation](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines), [WIF practices](https://cloud.google.com/iam/docs/best-practices-for-using-workload-identity-federation), [GitHub OIDC claims](https://docs.github.com/actions/reference/security/oidc) |
| `google_service_account_iam_member.github`                                                         | Lets only the external principal set emitted by a provider's constant boundary impersonate that provider's matching account.                                                                                                                                                                                                                             | Additive bindings avoid taking ownership of unrelated service-account policy. No account receives `roles/iam.serviceAccountTokenCreator`.                                                                                                                                                                                                                                                         | [Provider IAM resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_service_account_iam), [WIF service-account impersonation](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines#service-account)                                                                                                                                                                                  |
| `google_project_iam_custom_role.secret_metadata` and `.plan_metadata`                              | Keep two narrow gaps out of broad predefined roles. Foundation and operators manage secret containers without version access; plan reads only project IAM and Storage control-plane metadata. Recovery automation receives no permission to rewrite secret-container or backup-bucket IAM.                                                               | Deletion is blocked. Both permission lists are tested and neither can read a secret payload or backup object. During a clean-room rebuild, a human adds and later removes only the exact replacement runtime bindings listed by the recovery runbook. Custom roles have no fixed charge.                                                                                                          | [Provider resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_project_iam_custom_role), [custom roles](https://cloud.google.com/iam/docs/creating-custom-roles), [Secret Manager roles](https://cloud.google.com/secret-manager/docs/access-control), [Cloud Storage permissions](https://cloud.google.com/storage/docs/access-control/iam-permissions)                                                                |
| Project, bucket, managed-folder, service-account, and secret `*_iam_member` resources              | Encode additive least-privilege grants for each automation boundary and the declared human operators. Plan can refresh every bucket but can read objects only under the three state prefixes. Operators receive Private Logs Viewer because ordinary Logs Viewer excludes Data Access audit entries. Primitive Owner and Editor roles are never granted. | Deletion, replacement, or removal from state of these security resources is classified as protected by `ops/plan-summary.sh`. Operator access can be moved from a user to a group through review without changing secret payloads. IAM itself has no fixed charge.                                                                                                                                | [Provider IAM resources](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_project_iam), [IAM allow policies](https://cloud.google.com/iam/docs/allow-policies), [Cloud Logging access control](https://cloud.google.com/logging/docs/access-control)                                                                                                                                                                          |
| `google_secret_manager_secret.application`                                                         | Creates seven protected application secret containers, including distinct owner and read-only backup credentials for both PostgreSQL clusters. Payload versions are supplied through stdin by an authorized operator and never enter configuration, state, GitHub secrets, plans, or logs.                                                               | Deletion protection, provider deletion prevention, OpenTofu `prevent_destroy`, and a 30-day delayed version-destruction window apply. Secret versions and access operations are billable; empty metadata containers are negligible.                                                                                                                                                               | [Provider resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/secret_manager_secret), [Secret Manager best practices](https://cloud.google.com/secret-manager/docs/best-practices), [pricing](https://cloud.google.com/secret-manager/pricing)                                                                                                                                                                                |
| `google_project_iam_audit_config.management`                                                       | Enables Admin Read, Data Read, and Data Write audit records for Storage, Secret Manager, IAM, and STS so state-lock, payload-access, and token-exchange activity can be investigated. IAM's policy also covers IAM Credentials, which Google does not allow as a separate service-level audit configuration.                                             | Audit configuration is protected from destructive plans. Data Access log ingestion and retention can be billable, but the scope is limited to four security-critical service configurations instead of `allServices`.                                                                                                                                                                             | [Provider resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_project_iam_audit_config), [Cloud Audit Logs](https://cloud.google.com/logging/docs/audit), [IAM Credentials audit logs](https://cloud.google.com/iam/docs/audit-logging/audit-logging-iamcreds), [Logging pricing](https://cloud.google.com/logging/pricing)                                                                                            |

## Plan artifact expiration

The state bucket declares two-day expiration under `bootstrap/plans/`, `foundation/plans/` and
`release/plans/`, and for objects under `services/` ending in `/plan.tfplan` or `/plan.metadata.json`.
The service prefix and suffix must both match; state, locks, private inputs and foundation coordinates
are excluded. Their existing version-retention rule remains unchanged.

[Cloud Storage lifecycle](https://docs.cloud.google.com/storage/docs/lifecycle) acts asynchronously.
In this versioned bucket it first makes a live plan noncurrent, then deletes that version; seven-day
soft delete still permits recovery. Custody metadata independently enforces the exact 24-hour apply
deadline, including for restored objects. Storage cleanup never authorizes applying a plan.

Declaring the rule does not install it. Before activating the service-job writer, an operator must
use the [protected bootstrap plan/apply](../ops/README.md#protected-workflow-operations) and verify
the bucket's lifecycle selectors, versioning and soft delete through the
[storage inspection](../docs/runbooks/bootstrap-management-plane.md#9-verify-resources).
Removing or broadening this rule requires another policy review.

## Automation trust boundaries

The four infra providers trust GitHub issuer `https://token.actions.githubusercontent.com`, organization ID
`131281268`, repository ID `1344262359`, repository `a-novel/infra`, and
`refs/heads/master`. Names are retained for audit readability; the numeric IDs prevent a renamed or
re-created organization/repository from inheriting trust.

| Boundary     | Exact workflow on `master`          | Required environment claim                                               | Effective authority                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ------------ | ----------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `plan`       | `.github/workflows/drift.yaml`      | None; pull-request jobs still receive no provider and no cloud identity. | Read resource, IAM, and bucket metadata plus each state prefix. It cannot create lock objects, mutate cloud resources, read backup or receipt objects, or read secret payloads.                                                                                                                                                                                                                                                             |
| `foundation` | `.github/workflows/foundation.yaml` | `production-foundation`                                                  | Manage management-plane and workload foundations after approval, including IAM and bucket configuration. This high-trust identity has no standing secret-version grant, but its IAM authority is security-sensitive and therefore independently approved and audited.                                                                                                                                                                       |
| `release`    | `.github/workflows/release.yaml`    | `production-release`                                                     | Write release-root state and receipts, read secret-version metadata without payloads, promote verified images, and operate only the declared release resources. It has no project IAM, backup-read, recovery, or secret-payload access.                                                                                                                                                                                                     |
| `recovery`   | `.github/workflows/recovery.yaml`   | `production-recovery`                                                    | Read normal state for reconstruction, write only the four nested recovery state/plan prefixes, read only committed backup manifests, successful production receipts, and secret-version metadata without payloads, and write only `recovery/` evidence. It cannot rewrite management-project IAM. Production grants only source-registry read; a human adds exact replacement-runtime payload bindings and temporary parent/billing grants. |

The workflow filenames are part of the cloud trust policy before the workflows exist. Renaming one is
a security migration: update and apply the provider condition under foundation approval, land the
new workflow, verify authentication, and only then remove the old path.

These four providers and the pool remain bootstrap-owned. Opt-in
[service projects](../modules/workload-project/README.md#release-boundary) add foundation-owned
providers within that pool, project-local release accounts, and disjoint `services/<project-id>/`
state/receipt folders in the existing buckets. Their service-specific environments and constant
principal mappings cannot satisfy the legacy bindings. Bootstrap does not adopt these child
resources, and current release/recovery paths remain unchanged. Foundation's bucket and federation
administration remains an explicit high-trust exception to service isolation.

The plan identity deliberately keeps Storage Object Viewer instead of a write-capable backend role.
Its authenticated drift workflow must use `tofu plan -lock=false` and share a root-specific GitHub
concurrency group with every writer. That serialization makes the read-only exception safe without
granting permission to create `.tflock` or state objects. OpenTofu documents the tradeoff in its
[`plan` locking option](https://opentofu.org/docs/cli/commands/plan/#other-options).

## Platform visual-test storage

[`visual-tests.tf`](./visual-tests.tf) owns Drive API enablement and keyless identities from `visual_test_platforms`.
A Workspace administrator configures candidate folder grants and trusted maintenance Manager membership
in the dedicated **CI - Platform** Shared Drive.
Studio uses `studio/ci/references` and `studio/ci/results`. The
[visual-test storage runbook](../docs/runbooks/visual-test-storage.md) covers setup, verification,
retention and recovery. This configuration adds no visual-test GCS buckets.

| Address                                                                                             | Purpose and authority                                                                                                                                                                                                                                                                                                                    | Lifecycle and cost                                                                                                                                                                                    |
| --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `google_project_service.management["drive.googleapis.com"]`                                         | Enables Drive requests charged to the management project's API quota. Shared Drive storage belongs to Workspace.                                                                                                                                                                                                                         | Kept enabled on removal from configuration. Standard API usage currently has no additional charge; future overage policy is linked below.                                                             |
| `google_service_account.visual_tests["studio-ci"]` and `["studio-maintenance"]`                     | Separate keyless candidate and trusted maintenance identities. They receive no project-wide roles, state, backup or secret access.                                                                                                                                                                                                       | `prevent_destroy`; replacing an account requires updating Workspace membership and consumer coordinates. Accounts need no paid Workspace seat.                                                        |
| `google_iam_workload_identity_pool_provider.visual_tests["studio-ci"]` and `["studio-maintenance"]` | Existing pool and GitHub issuer, owner ID `131281268`, Studio repository ID `1338436652` and exact repo name. CI accepts `main.yaml` branch pushes/merge groups. Maintenance accepts master `main.yaml` pushes for publication and master `visual-tests.yaml` workflow-run, pull-request-target, delete and schedule events for cleanup. | Provider-owned `studio-visual-ci` / `studio-visual-maintenance` boundaries, canonical audience, provider deletion prevention and `prevent_destroy`. Workflow renames require a reviewed trust change. |
| `google_service_account_iam_member.visual_tests["studio-ci"]` and `["studio-maintenance"]`          | Each constant provider boundary can impersonate only its matching account. Drive access is separately authorized by folder grants and separately verified maintenance deletion authority.                                                                                                                                                | Additive Workload Identity User bindings. Removing a binding disables federation. No account keys, Token Creator grant or domain-wide delegation.                                                     |

Provider references: [API service](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_project_service),
[service account](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_service_account),
[federation provider](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/iam_workload_identity_pool_provider),
[account IAM](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_service_account_iam).
Google documents [GitHub federation](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines),
[Shared Drives](https://developers.google.com/workspace/drive/api/guides/about-shareddrives),
[Drive roles](https://developers.google.com/workspace/drive/api/guides/ref-roles) and
[API limits and billing](https://developers.google.com/workspace/drive/api/guides/limits).

The `visual_tests` output exposes the OAuth scope, per-platform provider/account pairs, folder paths
and required Drive/folder roles. These roles are a handoff contract, not Workspace permissions applied by OpenTofu. Infra
PR checks stay cloud-blind. Candidate CI can create and edit evidence in the platform results folder;
only trusted maintenance can replace references or permanently delete batches. Maintenance has owner-approved `organizer` membership on **CI - Platform** for permanent deletion.
That Google permission covers all platform folders in this dedicated Drive; candidate access stays
limited to its own folder pair. The trusted workflow limits operations to its platform folders and repository. Workspace operators
review effective membership, sharing restrictions and storage usage separately from Google Cloud IAM.

## Disabled JSON Keys native-backup custody

`json_keys_pgbackrest = null` creates no native-backup resources. The optional object's
`workload_project_id` identifies the independently registered JSON Keys service project whose
`agora-backup-repository` account already exists. This is syntax-checked, not discovered or authorized by HCL;
the operator must reconcile it with the protected service registration before any opt-in.
Its optional `tls_credentials` flag defaults to false; storage custody alone creates no TLS secrets.
The independent `noncurrent_cleanup` flag also defaults to false; its
[retention policy](#disabled-noncurrent-cleanup) needs separate activation approval.

| Address                                                                                                       | Purpose and authority                                                                                                                | Lifecycle and cost                                                                                                                             |
| ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `google_storage_bucket.pgbackrest["json-keys"]`                                                               | Separate management-owned EU repository; private uniform access, versioning, seven-day unlocked retention and seven-day soft delete. | `prevent_destroy` and `force_destroy=false`; no age-based lifecycle deletion of physical chains. Every retained generation is billable.        |
| `google_project_iam_custom_role.pgbackrest[writer/recovery]`                                                  | Writer has object create/get/list/delete. Recovery has create/get/list/restore, without delete or policy permissions.                | Deletion-protected role definitions in the bucket's management project; no project-wide role binding.                                          |
| `google_service_account.pgbackrest_recovery["json-keys"]`                                                     | Separate management-side identity, created disabled.                                                                                 | Deletion-protected, keyless, with no federation, attachment or impersonation grants. Enabling it requires a separate reviewed recovery change. |
| `google_storage_bucket_iam_member.pgbackrest_writer/pgbackrest_recovery["json-keys"]`                         | Only the dedicated repository host and recovery identity receive the corresponding role on the native bucket.                        | Additive grants; inspect inherited access separately. No grant on logical backups, peers, secrets or state.                                    |
| `google_storage_bucket_iam_member.foundation_admin/operator_admin` with the `pgbackrest-json-keys` bucket key | Existing management administrators maintain this bucket through exact-bucket grants.                                                 | No new project-wide permission. Initial bucket creation still requires separately approved bootstrap authority.                                |

Provider references: [bucket](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/storage_bucket),
[custom role](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_project_iam_custom_role),
[service account](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_service_account),
[bucket IAM](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/storage_bucket_iam).
Google documents [retention](https://docs.cloud.google.com/storage/docs/bucket-lock),
[versioning and soft delete](https://docs.cloud.google.com/storage/docs/soft-delete),
[object permissions](https://docs.cloud.google.com/storage/docs/access-control/iam-permissions) and
[disabled identities](https://docs.cloud.google.com/iam/docs/service-accounts-disable-enable).

The `json_keys_pgbackrest` output supplies non-secret coordinates after the declared grants. It is
not published into service configuration and does not authorize recovery or attest backup health.
The protected bootstrap input materializer already preserves this optional object; default omission
needs no new CLI, workflow or state root. Keep it absent from protected inputs during code review.

The [service foundation](../environments/service-foundation/README.md#optional-stopped-repository-host)
owns the repository identity and stopped VM. After separately approved provisioning, reconcile that
identity before applying this bucket grant. The database identity receives no native-storage access;
the repository identity receives no database password. These independent roots require that explicit
ordering, not an inferred cross-state dependency.

Provisioning, host access to instance credentials, WAL configuration, scheduling, monitoring and
recovery activation remain blocked by the [native adoption gates](../docs/runbooks/backup-and-restore-postgresql.md#native-backup-preparation).
No host metadata, firewall, job, schedule, image or logical-backup policy changes here. Seven-day
retention and soft delete protect individual generations; they do not guarantee an old full backup
outlives every dependent differential. Native expiry, version cleanup, storage cost and restoration
must be proven together before activation. No automatic expiry or retention lock is enabled.

### Disabled noncurrent cleanup

`json_keys_pgbackrest.noncurrent_cleanup = true` prepares one GCS lifecycle rule: delete only
noncurrent generations at least seven days after they became noncurrent. It does not expire live
objects, count newer versions, change IAM, or add a worker. pgBackRest alone owns live backup-chain
and WAL expiry; automatic native expiry remains off.

Seven-day bucket retention and seven-day soft delete remain unchanged. A versioned, name-based
delete makes an object noncurrent; actual generation deletion later enters soft delete. The
seven-plus-seven-day sequence is a minimum protection window after becoming noncurrent, not an
exact deletion deadline: [lifecycle processing is asynchronous](https://docs.cloud.google.com/storage/docs/lifecycle).
Live, noncurrent and soft-deleted bytes remain billable until removed. Native expiry without this
cleanup cannot bound versioned storage growth.

Retained backup sets keep their live dependencies, but old repository-time views have finite
generation retention. Soft-delete repair creates a new generation and may not satisfy an earlier
repository-time cutoff; changing that selector needs explicit recovery approval. Complete the
[human-only expiry acceptance](../docs/runbooks/backup-and-restore-postgresql.md#native-expiry-acceptance)
before enabling either cleanup mechanism. Existing logical backups and snapshots are unchanged.

### Disabled TLS credential custody

Setting `json_keys_pgbackrest.tls_credentials = true` additionally creates three protected containers
through `google_secret_manager_secret.application` and four exact-secret accessor bindings through
`google_secret_manager_secret_iam_member.pgbackrest_tls`. The existing operator Accessor and
Version Manager grants cover these containers too. The seven default application containers and
their resource addresses stay unchanged. No secret version, signing service, certificate issuer or
host delivery process is created; keep this flag off until separately approved provisioning.

| Secret ID                                    | PEM payload contract                                                                       | Runtime readers in the selected service project |
| -------------------------------------------- | ------------------------------------------------------------------------------------------ | ----------------------------------------------- |
| `production-json-keys-pgbackrest-ca`         | Public CA certificate bundle only (`PGBACKREST_CA_PEM`). Never the CA private key.         | `agora-database`, `agora-backup-repository`     |
| `production-json-keys-pgbackrest-database`   | Client certificate/chain followed by its matching private key (`PGBACKREST_IDENTITY_PEM`). | `agora-database` only                           |
| `production-json-keys-pgbackrest-repository` | Server certificate/chain followed by its matching private key (`PGBACKREST_IDENTITY_PEM`). | `agora-backup-repository` only                  |

The native TLS proof uses one PEM file for both pgBackRest certificate and key options. Keeping that
pair in one secret version prevents delivery from mixing independently rotated versions; it requires
no custom envelope, parser or crypto library. Select explicit numeric versions, never `latest`.
Secret IAM applies to every enabled version, so a version pin is not an IAM boundary. No peer,
application, release or recovery identity receives a TLS payload binding here; inspect inherited
policies and prove cross-key denial after any approved provisioning.

Before uploading real credentials or activating a host, review these remaining operations:

- Name the operator responsible for issuance, renewal and expiry alerts. Keep the signing key
  offline and outside both hosts and OpenTofu. Define certificate lifetimes, the server DNS SAN and
  the exact client identity/stanza mapping before issuance; no automated issuer is implied here.
- Retrieve the selected versions through each host's own instance identity into private ephemeral
  files. Bind only that host's identity bundle and public trust into its container. Reject invalid,
  expired, mismatched or wrong-name credentials before starting; never log them or put payloads in
  state, instance metadata or environment variables. Host delivery is not implemented by this slice.
- Validate a staged renewal with both trust paths before retiring old versions. Disabling a Secret
  Manager version does not revoke a certificate already loaded by a running process. A compromised
  key needs removal of its accepted identity/trust as appropriate, credential replacement and
  connection draining, with recovery and rollback reviewed separately.

The current `ops/add-secret-version.sh` accepts single-line passwords, **not these multiline PEM
contracts**. Do not extend its allowlist or upload credentials ad hoc; approve the issuance and
delivery procedure first. The [offline proof](../proofs/pgbackrest/README.md#native-repository-transport)
checks native format and handshake behavior, not live host isolation, issuance or rotation.
Use [Secret Manager's access and version guidance](https://docs.cloud.google.com/secret-manager/docs/best-practices)
and the [pgBackRest TLS options](https://pgbackrest.org/configuration.html) for that implementation.

## Secret contracts

Container names include the environment and owning component. The annotation is a public contract
name, never a value.

| Secret ID                                            | Runtime contract           | Purpose                                                     |
| ---------------------------------------------------- | -------------------------- | ----------------------------------------------------------- |
| `production-authentication-postgres-password`        | `POSTGRES_PASSWORD`        | Authentication database owner password.                     |
| `production-authentication-postgres-backup-password` | `POSTGRES_BACKUP_PASSWORD` | Authentication read-only logical-backup password.           |
| `production-authentication-smtp-sender-password`     | `SMTP_SENDER_PASSWORD`     | Production SMTP credential.                                 |
| `production-authentication-super-admin-password`     | `SUPER_ADMIN_PASSWORD`     | One-time Authentication administrator bootstrap credential. |
| `production-json-keys-app-master-key`                | `APP_MASTER_KEY`           | JSON Keys application master key.                           |
| `production-json-keys-postgres-password`             | `POSTGRES_PASSWORD`        | JSON Keys database owner password.                          |
| `production-json-keys-postgres-backup-password`      | `POSTGRES_BACKUP_PASSWORD` | JSON Keys read-only logical-backup password.                |

For the seven application contracts above, runtime identities live in the workload project, so the foundation root owns their additive
payload bindings. Authentication receives its owner password and SMTP credential; its initializer
receives the same owner password and the super-admin password. JSON Keys receives its owner password
and master key. The database host receives both owner and backup passwords, while the backup identity
receives only both backup passwords. Restore and scheduler receive no payload access. Project-wide
Secret Accessor grants are forbidden.

## Operator procedures

- [Bootstrap and verify the management plane](../docs/runbooks/bootstrap-management-plane.md)
- [Deploy and roll back production](../docs/runbooks/deploy-production.md)
- [Recover into a disposable project](../docs/runbooks/disaster-recovery.md)
- [Back up and restore PostgreSQL](../docs/runbooks/backup-and-restore-postgresql.md)
- [Add or rotate a secret version](../docs/runbooks/secret-versions.md)
- [Recover a prior state generation](../docs/runbooks/state-recovery.md)

Read the [architecture](../docs/architecture.md) and
[Google Cloud provider guide](../docs/google-cloud.md) before changing this root. A resource change
must update this inventory, its mocked invariants, and the affected runbook in the same pull request.
