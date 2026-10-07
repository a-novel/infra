# Production foundation root

This root owns durable production controls that survive ordinary application releases. It defines
the protected private workload project, private routing, workload identities, regional image registry,
quota ceilings, budget alerts, bounded logging, and two private stateful PostgreSQL hosts. Each host
uses a pinned Container-Optimized OS image, a preserved data disk, an immutable one-member managed
instance group, and native pgBackRest recovery on its service-owned repository.
Foundation also owns recovery identities, bucket IAM, capacity alert policies,
and separate human cost/operations channels; the existing drift workflow owns the bounded public
health check, while scale-to-zero jobs remain release resources.

Production projects, database disks/groups, network, runtime identities, registry, alerts and
budgets retain native deletion protections. Immutable instance templates remain replaceable only
through reviewed maintenance. Recovery uses the separate isolated service-recovery root; the retired
whole-production recovery mode is rejected.

## State and authority

Optional service-owned project shells are declared by `service_projects` (default `{}`). They use
the reusable [workload-project module](../../../modules/workload-project/README.md), attach to this
root's existing network through Shared VPC, and join the existing budget. These new projects and
the Shared VPC host/attachments retain the same deletion guards as the production foundation. Foundation also prepares each service's isolated state/receipt
folders in the management plane, creates the required Google-managed service agents, and grants the Cloud Run
agent access to the exact foundation subnet. Application authority and active workflows are unchanged.
No existing workload or deployment authority moves with this change. Follow the
[service-project onboarding boundary](../../../docs/runbooks/provision-service-projects.md) before activation.

`service_recovery_projects` separately registers disposable native-recovery destinations as
`project ID → service` (default `{}`). It creates no project, IAM grant or host. Destinations must
not match any live management, private, public API, platform or dedicated service project. Protected preparation and
read-only state inventory consume this registration; see the
[inactive recovery root](../../service-recovery/README.md#guarded-host-preparation).

The protected foundation identity uses the `foundation/` object boundary in the management state
bucket and requires human approval for every apply. It is the deliberate high-trust identity that
maintains both this root and post-bootstrap management-plane configuration. It can administer IAM
but has no standing Secret Manager payload access and cannot use a long-lived service-account key.

The provider starts in `management_project_id` because the workload project might not exist yet. The
root then creates `workload_project_id` under an existing organization/folder, or declaratively
imports the empty human-created project used by the standalone path. The import appears in the same
reviewed saved plan and becomes inert once state tracks the project. Resources that belong to
production explicitly target that project. State remains in the management project, so deleting or
rebuilding the workload project does not delete the recovery record. See OpenTofu's
[configuration-driven import](https://opentofu.org/docs/language/import/).

The Google provider removes the default VPC only while creating a project; importing an existing
project skips that create-time cleanup. The `adopt_default_network` switch is off by default. One
reviewed change enables it to import an audited empty default VPC without modifying it; a second
change disables it and carries the repository's deletion label. Review therefore never conflates
state adoption with resource deletion.

Protected foundation owns native deployment authority and exact runtime attachment grants.
Conditional invocation grants distinguish migration, scheduled and internal-service calls;
the scheduler cannot deploy jobs or read secrets. Named humans alone receive initializer
execution authority and access to its dedicated identity. Routine deployment has no direct
Secret Manager payload access; Cloud Run resolves exact numeric versions as each dedicated runtime identity.

Merging or validating this code creates nothing, and no operator should run this root manually. The
protected workflow creates a private plan and applies that exact plan in separate approved runs from
`master`. Follow the [workload foundation runbook](../../../docs/runbooks/provision-workload-foundation.md)
only after resource creation has been explicitly authorized.

## Implemented security and cost boundaries

- The custom VPC has no default route, Cloud NAT, router, Serverless VPC Access connector, public
  load balancer, or public IP resource. Two explicit routes reach only Google's restricted API
  ranges; IAP TCP forwarding uses Google's non-removable system route.
- Private Google Access and private `googleapis.com`, `pkg.dev`, and `run.app` zones keep supported
  Google API, registry, and internal Cloud Run traffic on Google's restricted path. The restricted
  VIP blocks APIs that do not support VPC Service Controls; it does not create a service perimeter.
- Tagged private workloads can reach TCP `443` on those Google ranges. JSON Keys can reach only TCP
  `5432` and Authentication only TCP `5433`. Native backups use the database host's local socket
  and authenticated repository connection. A lower-priority VPC-wide rule denies every remaining egress path,
  including traffic from an accidentally untagged endpoint.
- PostgreSQL ingress is subnet-scoped and targets only the database host tag. Direct VPC network
  tags cannot be used as Cloud Run ingress source tags, so database authorization
  also relies on tagged caller egress, exact credentials, and database roles. SSH targets only the
  database tag and accepts only the IAP TCP-forwarding range.
- The stateful managed instance group has one Shielded VM, no external interface, no autoscaler, and
  no health-based repair loop. It preserves the VM name, private address, and balanced data disk
  across controlled boot-VM replacement. The host remains idle until a complete database release is
  enabled.
- Each PostgreSQL image runs on its own fixed Docker bridge and publishes only one private host port.
  Host firewall chains permit replies to private clients and native backup TLS to the service's exact
  repository address and port. They reject other connections initiated by either database container,
  including Docker DNS, peer-container, host, metadata, and internet access. Native backup workers
  must use the database's exact immutable image digest.
- Startup reads the exact owner password version and promoted image with the database identity,
  then writes logs and guest metrics. The password lives in a root-owned `/run`
  file and enters the container through `POSTGRES_PASSWORD_FILE`. A local server-side block reads and
  quotes the value with statement, duration, audit, and error logging disabled for that session;
  client output is discarded. Payloads never cross the Docker exec stream or appear in client SQL,
  metadata, environment variables, process arguments, server logs, or OpenTofu state. The
  value must be a 32–128 character URL-safe string. Native physical backups use TLS identities
  and the local PostgreSQL socket; startup creates no backup SQL login.
- Named operators use OS Login through IAP on port `22`. Their account-level Service Account User
  grant satisfies OS Login's `actAs` check but grants no token-minting role. Protected database
  maintenance owns the selected group's image, revision and owner-version metadata. Compute reauthorizes the full
  member specification for that patch, so separate bindings grant group update at project scope,
  VM and boot-disk prerequisites only for the generated `agora-database-*` prefix, attachment only
  on the two named service data disks, template reads only on the exact template, and Network User only
  on the production subnet. A four-permission project role covers the generated stateful internal
  address because Compute Address has no resource IAM policy. The helper refuses an existing map
  with any missing or unknown key before mutation. Before a database image change or migration it
  requires a fresh native full backup and exact-set isolated SQL restore on existing repository capacity. The
  boundary cannot mutate snapshots or external addresses. It has no VM/disk delete, start,
  stop, or IAM permission. Only the fixed protected helper may use the coarse
  group update.
- Code deprivileges Google-created default service accounts, separates runtime identities
  by workload, and creates no user-managed keys. Authentication and JSON Keys may write OTLP traces
  and logs through the Telemetry API. Exact Secret Manager bindings follow each runtime contract.
  Native repository writes and separately disabled recovery reads use service-owned identities;
  the former shared logical backup identities are retired. The runbook enforces
  default-role and key-creation/upload policies when an organization exists and records the
  zero-key fallback for standalone projects.
- The Docker repository uses immutable tags and deletion prevention. Cleanup remains in dry-run
  until release receipts prove rollback images are retained.
- Regional Cloud Run and Compute Engine quota preferences limit accidental scale. A 60-unit monthly
  budget spans the management and workload projects and alerts both human channels at current and
  forecasted 50%, 75%, 90%, and 100% in the billing account currency; it is not a hard spending cap.
- The default log bucket retains 30 days. Only successful Cloud Run request logs for the exact
  `/v2/ping` and `/v2/healthcheck` paths are excluded; failures, application logs, and audit records
  remain.
- Five Monitoring policies alert on sustained CPU above 70%, memory above 70%/85%, and guest disk
  usage above 70%/85% (including the data filesystem). Native backup failure and freshness policies are owned by each service foundation.
  Separate policies alert above a 10% Authentication 5xx ratio and cover
  application-job failure or three hours without successful key rotation. The read-only drift
  workflow makes one exact Authentication-and-dependencies check every three hours. The release
  root independently keeps one warm instance per production service.
  Container connection and resource measurements remain operator checks in the database-host
  runbook.

## Resource inventory

`module.service_project` owns each exceptional opt-in project's shell
and state/receipt folder grants; its
[module inventory](../../../modules/workload-project/README.md#ownership) lists the resources.
`google_compute_shared_vpc_host_project.production` enables the existing workload project as the
network host when `shared_vpc_enabled` is true or the map is nonempty.
`google_compute_shared_vpc_service_project.service` attaches each shell. Host and attachments retain
`prevent_destroy`; the host also retains provider `PREVENT`. The existing budget adds each
registered project's number. Shared VPC adds no network
appliance; traffic and later workloads retain their product usage charges. See the
[host resource](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/compute_shared_vpc_host_project),
[attachment resource](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/compute_shared_vpc_service_project),
and [Shared VPC overview](https://cloud.google.com/vpc/docs/shared-vpc).

`google_project_iam_member.service_run_network_viewer` grants each service project's Cloud Run agent
network visibility in the host; `google_compute_subnetwork_iam_member.service_run` limits Network User
to the production subnet. Service registration does not extend the existing HTTPS or database
egress tags; the VPC-wide deny still applies. Empty-map and recovery plans add none of these grants. Live verification
must test [Shared VPC Direct VPC access](https://docs.cloud.google.com/run/docs/configuring/shared-vpc-direct-vpc)
and denied database reachability before activation.

`pgbackrest_repository_services = []` adds no rules. Selecting `json-keys` from `service_projects`
prepares four identity-scoped native rules in [`pgbackrest-network.tf`](./pgbackrest-network.tf):

| Resource suffix (`google_compute_firewall.pgbackrest_*`) | Source → destination                                        | Permit   |
| -------------------------------------------------------- | ----------------------------------------------------------- | -------- |
| `database_egress`                                        | Selected database identity → existing subnet                | TCP 8432 |
| `repository_ingress`                                     | That database identity → its dedicated repository identity  | TCP 8432 |
| `google_egress`                                          | Repository identity → existing restricted Google API ranges | TCP 443  |
| `iap_ingress`                                            | IAP TCP-forwarding range → repository identity              | TCP 22   |

The receiving identity rule enforces the peer boundary: classic egress rules cannot select a
destination service account. Do not add source CIDRs to the TLS rule; Google combines them with the
identity using **OR**, not **AND**. The VPC-wide egress deny remains unchanged, including no repository
connection back to PostgreSQL. Recovery ignores the copied production opt-in and creates no rules.
No new route, NAT, public IP, IAM grant or firewall logging is introduced. These rules have no fixed
charge; traffic retains normal usage charges. Removal still requires the managed-deletion gate.

Before a separately approved activation, attach the service project and create both identities in
service foundation; review effective rules and attachment authority. The firewall does not grant
OS Login/IAP or API permissions, filter Google's always-reachable metadata server, or configure
native TLS. Existing database-container outbound/metadata isolation and backup schedules remain
unchanged. Certificate delivery, exact host allow-list, repository runtime and live positive/peer
denial checks remain activation prerequisites. See [Google's account selectors and Shared VPC rules](https://docs.cloud.google.com/firewall/docs/firewalls#service-accounts-vs-tags),
the [pinned provider resource](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/compute_firewall.html.markdown),
and [pgBackRest's TLS port](https://pgbackrest.org/configuration.html#section-repository/option-repo-host-port).

### Shared native database

`native_backups = {}` retains the existing startup path. Each service entry supplies its private
repository IP, service-scoped database/credential image digests, distinct TLS `client_name`,
numeric CA/database identity versions and `wal_archiving` (default false). It reuses
the [database-runtime module](../../../modules/database-runtime/README.md) through this
root's existing instance template, singleton group and preserved data disk.

Apply startup-script changes only through protected database maintenance, including
its fresh native backup, isolated SQL restore and exact no-surge replacement review. Peer services,
database metadata/image, disks, addresses and VM sizes must remain unchanged. The entrypoint
requires the deployed database digest to equal the repository/worker digest. This is not a
database upgrade or ownership transfer to service foundation.

Maintenance requires WAL archiving already active for every selected service. It runs the existing
check/full workers, binds the new full backup to the source PostgreSQL system ID, and restores that
exact set on the existing repository VM. The separate SQL container has no network or credentials;
it pauses at backup consistency and checks the same schema/roles/extensions as disaster recovery.
This routine check does not assert an independently captured application-data hash. Scratch restores
are limited to backups below 2 GiB with three times their size plus 1 GiB free; larger databases stop
for a capacity review rather than allocating resources automatically.

All selected services pass before any replacement. A failure or uncertain SSH response preserves
the maintenance hold and private diagnostics, with no automatic retry. Successful checks remove
only their own stopped containers and scratch copies. The workflow uses its existing host authority
and IAP access restricted to each database address on port 22.

Boot starts PostgreSQL under systemd. Enrolled schedules follow the database lifecycle;
disabled schedules remain stopped. TLS issuance, runtime identity/egress checks,
native backup/SQL-restore proof and monitoring remain activation requirements; see
[shared-host activation](../../../docs/runbooks/accept-native-backups.md#shared-host-activation).
Do not apply this opt-in to a recovery copy.

For the existing JSON Keys installation, move the complete former `json_keys_native_backup`
value to `native_backups["json-keys"]` and add its already-issued client name. Stage the protected
input update with the code change before any plan: omitting the entry would select the old startup
path. Migrate the service-foundation repository runtime to the same explicit client name. Keep
all image digests, numeric TLS versions and WAL settings unchanged during this configuration move;
publish and verify the service-aware credential-loader image before selecting it in a live plan.

Both Google providers are pinned in [`versions.tf`](./versions.tf); only service-agent creation uses
`google-beta`. Rows group repeated resources that share a
single boundary; their `for_each` keys are part of the reviewed configuration and mocked tests.

`google_project_iam_custom_role.foundation_firewall` and
`google_project_iam_member.foundation_firewall` grant only VPC firewall create/update/delete in the
workload project to the foundation identity. Network Admin
supplies read permissions. Firewall resources depend on this binding; IAM propagation still applies.
The role adds no fixed cost or payload access. Its removal requires the managed-deletion gate.
For a partially applied rollout with an obsolete firewall still in state, follow
[Repair foundation firewall access](../../../docs/runbooks/repair-foundation-firewall-access.md).

| OpenTofu address                                                                                                                                                  | Agora purpose and boundary                                                                                                                                                                                                                                                                                                     | Lifecycle, recovery, and cost                                                                                                                                                                                                                                                                                                                                                                                                                                                               | References                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `google_project.workload` and `google_project_service.workload`                                                                                                   | Create the production project without a default network and keep the fifteen APIs needed by this and later workload roots enabled. The project may use one organization or folder parent, never both.                                                                                                                          | Project deletion is blocked by Google and OpenTofu. Removing an API from code does not disable it. Project creation grants its creator temporary Owner; the runbook removes that primitive role after exact IAM converges. APIs have no fixed charge.                                                                                                                                                                                                                                       | [Project resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_project), [Project Service resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_project_service), [projects](https://cloud.google.com/resource-manager/docs/creating-managing-projects), [service usage](https://cloud.google.com/service-usage/docs/enable-disable)                                                                                                                                                                                                                                                                                                                                                              |
| `google_project_default_service_accounts.workload`                                                                                                                | Remove project roles from Google-created default service accounts while keeping the accounts recoverable. Dedicated runtime identities remain the only accounts attached to workloads.                                                                                                                                         | `DEPRIVILEGE` is best-effort because Google exposes no formal default-account inventory. The all-managed-resource plan gate blocks removal, and the runbook independently verifies primitive roles and user-managed keys. IAM has no fixed charge.                                                                                                                                                                                                                                          | [Default Service Accounts resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_project_default_service_accounts), [default service-account practices](https://cloud.google.com/iam/docs/best-practices-service-accounts), [Compute Engine service accounts](https://cloud.google.com/compute/docs/access/service-accounts)                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `google_compute_network.default_adoption`                                                                                                                         | Conditionally import the audited empty default VPC that survives an existing-project import. `ignore_changes = all` prevents provider-created metadata from modifying or replacing it.                                                                                                                                         | `adopt_default_network` defaults to `false`. A recovery pull request enables it for an import-only apply; a second pull request disables it and must carry `allow-resource-deletion` before the protected apply deletes the VPC. The unused VPC, subnets, and routes have no fixed charge between reviews.                                                                                                                                                                                  | [Network resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/compute_network), [configuration-driven import](https://opentofu.org/docs/language/import/), [lifecycle `ignore_changes`](https://opentofu.org/docs/language/meta-arguments/lifecycle/#ignore_changes), [default VPC network](https://cloud.google.com/vpc/docs/vpc#default-network)                                                                                                                                                                                                                                                                                                                                                                                                |
| `google_compute_network.production`, `google_compute_subnetwork.production`, and `google_compute_route.restricted_google_apis`                                    | Provide one regional custom-mode IPv4 network and `/24` subnet with Private Google Access. Default routes are deleted; explicit routes reach only `199.36.153.4/30` and `34.126.0.0/18`.                                                                                                                                       | Network and subnet deletion are blocked. Routes are reproducible and carry no fixed charge; traffic can be billable. Expanding or replacing the subnet requires a separately planned migration.                                                                                                                                                                                                                                                                                             | [Network resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/compute_network), [subnetwork resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/compute_subnetwork), [route resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/compute_route), [VPC](https://cloud.google.com/vpc/docs/vpc), [Private Google Access](https://cloud.google.com/vpc/docs/configure-private-google-access)                                                                                                                                                                                                                                                                                |
| `google_compute_firewall.allow_restricted_google_apis`, `.allow_postgres_egress`, `.deny_other_egress`, `.allow_postgres_ingress`, and `.allow_iap_ssh`           | Encode tagged private-workload allows followed by a VPC-wide deny-all egress fallback, restrict PostgreSQL to the production subnet/database target, and restrict operator SSH to IAP. No rule grants public ingress.                                                                                                          | Firewall changes have no fixed charge but can change reachability immediately. The sanitized plan blocks every managed-resource removal, and mocked tests assert priorities, ranges, ports, directions, and tags.                                                                                                                                                                                                                                                                           | [Firewall resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/compute_firewall), [VPC firewall rules](https://cloud.google.com/firewall/docs/firewalls), [Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc), [IAP TCP forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding)                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `google_compute_disk.database`, `google_compute_instance_template.database`, `google_compute_instance_group_manager.database`, and database instance data sources | Own two private, single-member database groups, each with an independent runtime identity and 50 GiB SSD-backed data disk.                                                                                                                                                                                                     | Each e2-medium uses a replaceable 20 GiB pd-balanced boot disk. Stateful replacement retains its data disk and private address. Retire the legacy shared VM before starting both replacements under the four-vCPU quota.                                                                                                                                                                                                                                                                    | [Disk resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/compute_disk), [Instance Template resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/compute_instance_template), [Instance Group Manager resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/compute_instance_group_manager), [stateful MIGs](https://cloud.google.com/compute/docs/instance-groups/configuring-stateful-migs), [stateful disks](https://cloud.google.com/compute/docs/instance-groups/configuring-stateful-disks-in-migs), [Container-Optimized OS](https://cloud.google.com/container-optimized-os/docs), [Persistent Disk](https://cloud.google.com/compute/docs/disks/persistent-disks) |
| `google_monitoring_alert_policy.database_capacity`                                                                                                                | Alert the existing operations channel on sustained host CPU and guest memory/disk thresholds.                                                                                                                                                                                                                                  | Five policies use native host metrics. Per-service native backup alerts are owned by the service foundation.                                                                                                                                                                                                                                                                                                                                                                                | [Alert Policy resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/monitoring_alert_policy), [COS Node Problem Detector](https://cloud.google.com/container-optimized-os/docs/how-to/monitoring-system-health)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `google_monitoring_alert_policy.authentication_error_rate` and `.application_jobs_unhealthy`                                                                      | Alert above a 10% five-minute Authentication 5xx ratio, on Authentication/JSON Keys job failure, or after three hours without successful JSON Keys rotation. The separate read-only drift workflow validates public Authentication plus all three exact dependency states every three hours.                                   | Two deletion-protected policies use native Cloud Run metrics. The synthetic check reuses the existing plan identity, private foundation configuration, and public-repository runner; it adds no Google resource, minimum instance, credential, custom metric, log parser, or controller. Recovery omits the policies and the production release switch disables the synthetic check.                                                                                                        | [Alert Policy resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/monitoring_alert_policy), [Cloud Run metrics](https://cloud.google.com/monitoring/api/metrics_gcp_p_z#gcp-run), [instance-based billing](https://cloud.google.com/run/docs/configuring/billing-settings), [scheduled workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule), [workflow notifications](https://docs.github.com/en/actions/concepts/workflows-and-actions/notifications-for-workflow-runs), [alert runbook](../../../docs/runbooks/respond-to-alerts.md)                                                                                                                                          |
| `google_dns_managed_zone.googleapis`, `.private_google_domain`, and their `google_dns_record_set` resources                                                       | Resolve `googleapis.com`, `pkg.dev`, and `run.app` through `restricted.googleapis.com` only inside the production VPC.                                                                                                                                                                                                         | Zone deletion is blocked and every managed record removal triggers the plan gate. Three private zones cost about USD 0.60/month plus query usage at current list prices.                                                                                                                                                                                                                                                                                                                    | [Managed Zone resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/dns_managed_zone), [Record Set resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/dns_record_set), [Private Google Access domains](https://cloud.google.com/vpc/docs/configure-private-google-access), [DNS pricing](https://cloud.google.com/dns/pricing)                                                                                                                                                                                                                                                                                                                                                                               |
| `google_project_iam_custom_role.foundation_project_metadata`, `google_project_iam_member.foundation`, and `.foundation_project_metadata`                          | Give the protected foundation identity exact administration roles plus project name/label updates without project deletion or movement authority. Primitive Owner and Editor are not declared.                                                                                                                                 | Custom-role deletion is blocked. Project creation's temporary Owner grant is removed only after these bindings apply and are verified. IAM has no fixed charge.                                                                                                                                                                                                                                                                                                                             | [Custom role resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_project_iam_custom_role), [Project IAM member](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_project_iam), [IAM allow policies](https://cloud.google.com/iam/docs/allow-policies)                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `google_tags_tag_key.cloud_run_invocation`, tag values/IAM, conditional invoker members, and Cloud Run custom roles                                               | Define five permanent invocation classes: `initializer`, `internal`, `recovery`, `release`, and `scheduled`. Foundation owns the routine bindings; named humans alone can attach and invoke `initializer`. Authentication can invoke only `internal`; scheduler only `scheduled`; disposable recovery callers only `recovery`. | Tags are IAM authorization attributes, not labels. Foundation's native service permissions separate definition updates from tag-restricted job invocation. The initializer deployer omits overrides and is assigned only to named humans, who must use the two-phase runbook. Tag/custom-role deletion is blocked. IAM and tags have no fixed charge.                                                                                                                                       | [Cloud Run job tags](https://cloud.google.com/run/docs/configuring/jobs/tags), [IAM tag conditions](https://cloud.google.com/iam/docs/conditions-resource-attributes#resource_tags), [Cloud Run IAM roles](https://cloud.google.com/run/docs/reference/iam/roles), [Custom role resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_project_iam_custom_role)                                                                                                                                                                                                                                                                                                                                                                              |
| `google_service_account.runtime` and `google_secret_manager_secret_iam_member.runtime`                                                                            | Create six dedicated application, initializer, database-host and scheduler identities with nine exact production payload bindings. Native repository identities and TLS access belong to the service foundations and management bootstrap.                                                                                     | Authentication cannot read the bootstrap administrator password; only its initializer identity receives that password and the Authentication owner password. This root creates no service-account key, secret version, logical-backup identity or legacy bucket access. Accounts and IAM have no fixed charge.                                                                                                                                                                              | [Service Account resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_service_account), [Secret IAM resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/secret_manager_secret_iam), [service-account practices](https://cloud.google.com/iam/docs/best-practices-service-accounts)                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `google_project_iam_member.application_telemetry`                                                                                                                 | Let the Authentication and JSON Keys runtime identities write OpenTelemetry traces and logs over OTLP to the Telemetry API. The role writes telemetry only; it cannot read traces, logs, or any other project data.                                                                                                            | Removing a binding stops that service exporting; requests keep working and the SDK reports each rejected export on stderr. Spans are billed past 2.5 million per billing account each month, and logs as Cloud Logging ingestion.                                                                                                                                                                                                                                                           | [IAM member resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/google_project_iam#google_project_iam_member), [Telemetry API](https://docs.cloud.google.com/stackdriver/docs/reference/telemetry/overview), [OTLP log ingestion](https://docs.cloud.google.com/stackdriver/docs/otlp-logs/overview)                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `google_artifact_registry_repository.production` and repository IAM members                                                                                       | Provide one regional Docker registry with immutable tags. Protected foundation may promote reviewed images; the private database host directly receives reader access. Same-project Cloud Run pulls use Google's service agent.                                                                                                | Repository deletion is blocked. Cleanup currently previews keeping all `receipt-*` tags and ten recent versions while deleting untagged versions older than 90 days. The first 0.5 GiB of storage is free at current list prices; excess storage and transfer are usage-priced.                                                                                                                                                                                                             | [Repository resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/artifact_registry_repository), [repository IAM](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/artifact_registry_repository_iam), [immutable tags](https://cloud.google.com/artifact-registry/docs/docker/immutable-image-tags), [cleanup policies](https://cloud.google.com/artifact-registry/docs/repositories/cleanup-policy), [pricing](https://cloud.google.com/artifact-registry/pricing)                                                                                                                                                                                                                                                  |
| `google_cloud_quotas_quota_preference.cost_cap`                                                                                                                   | Request regional ceilings of 8 vCPU, 16 GiB, and 4 Compute Engine CPUs using reviewed service-defined quota IDs. Google validates the configured IDs when applying the preferences.                                                                                                                                            | The Cloud Quotas API does not expose the Direct VPC instance limit as a preference for this project; release resources cap each service at three instances and each job at one task. The percentage safety bypass permits deliberate large decreases while Google's below-usage check remains enforced. Adjustment follow-up uses the monitored operator address; quota IAM remains on the foundation identity. Quotas are safety rails, not exact spending caps, and have no fixed charge. | [Quota Preference resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_quotas_quota_preference), [Cloud Quotas with Terraform](https://cloud.google.com/docs/quotas/terraform-support-for-cloud-quotas), [known issues](https://cloud.google.com/docs/quotas/known-issues), [Cloud Run quotas](https://cloud.google.com/run/quotas), [Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc)                                                                                                                                                                                                                                                                                                                      |
| `data.google_billing_account.workload`, project data, both `google_monitoring_notification_channel` resources, and `google_billing_budget.workload`               | Read billing currency/project numbers, then send the exact management-and-workload budget to separate cost and operations human channels. Current and forecast thresholds are 50/75/90/100%; default billing-account and project recipients are disabled.                                                                      | Channel and budget deletion are blocked. The operator verifies both existing channels after creation. Budgets/channels have no fixed charge and never stop resources or charges automatically.                                                                                                                                                                                                                                                                                              | [Billing Account data source](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/data-sources/billing_account), [Project data source](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/data-sources/project), [Notification Channel resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/monitoring_notification_channel), [Budget resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/billing_budget), [notification channels](https://cloud.google.com/monitoring/support/notification-options), [budgets](https://cloud.google.com/billing/docs/how-to/budgets)                                                                                                     |
| `google_logging_project_bucket_config.default` and `google_logging_project_exclusion.successful_healthchecks`                                                     | Bound default retention to 30 days and suppress only successful Cloud Run request logs for `/v2/ping` and `/v2/healthcheck`.                                                                                                                                                                                                   | Bucket deletion is blocked and remains unlocked so retention can change in code. Failed checks, application logs, and audit records remain. Ingestion or retention beyond free allowances is usage-priced.                                                                                                                                                                                                                                                                                  | [Log Bucket resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/logging_project_bucket_config), [Exclusion resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/logging_project_exclusion), [log buckets](https://cloud.google.com/logging/docs/buckets), [exclusions](https://cloud.google.com/logging/docs/exclusions), [pricing](https://cloud.google.com/logging/pricing)                                                                                                                                                                                                                                                                                                                                |

## Inputs and outputs

`management_project_id`, `workload_project_id`, `backup_bucket_name`, `billing_account_id`,
`cost_alert_email`, `operations_alert_email`, at least one `database_operator_principals` entry, and
at least one `authentication_initializer_principals` entry are required. Both principal sets accept
only `user:` or `group:` IAM members. `organization_id` or `folder_id` is optional and mutually
exclusive. `adopt_default_network` defaults to `false`; reviewers change its default in code for the
two-pull-request default-VPC recovery. Mocked tests keep it disabled.

Defaults keep production in `europe-west1` and the database in `europe-west1-c`, use
`10.20.0.0/24`, run one `e2-medium` per database, each with a 50 GiB `pd-balanced` data disk and a 20 GiB `pd-balanced` boot disk, give each PostgreSQL
container 0.75 vCPU and 1,536 MiB with no swap, cap each cluster at 50 connections, pin a named COS
image, set the alert-only budget to 60 whole billing-currency units, and apply the quota ceilings
recorded above. Machine type is limited to `e2-medium`, `e2-standard-2`, or `e2-standard-4`.
Disk size accepts only growth-oriented 10 GiB steps from 50 through 1,000 GiB. Cross-input checks
reserve at least 1 GiB and 0.5 vCPU for the host.

Billing and alert inputs are sensitive in OpenTofu; state remains private because sensitivity is a
display control. Password payloads are not OpenTofu inputs.

Outputs expose only identifiers required by later roots and recovery: workload project ID and number,
region, network/subnet IDs and tags, registry URI, runtime service-account emails, and the database
group, generated instance name, stateful private address, zone, ports, machine type, disk metadata,
and native backup enrollment. No credential, secret version, billing account, or notification address is
output.

Read the [architecture](../../../docs/architecture.md),
[Google Cloud provider guide](../../../docs/google-cloud.md),
[cost worksheet](../../../docs/costs/production.md), and
[workload foundation runbook](../../../docs/runbooks/provision-workload-foundation.md) before changing
this root. The [database-host runbook](../../../docs/runbooks/operate-postgresql-host.md) owns its
verification, capacity, rollback, and failure procedures. The
[PostgreSQL recovery runbook](../../../docs/runbooks/backup-and-restore-postgresql.md) owns native backup chains,
restores, retention, alerts, and RPO/RTO evidence. Any resource change must update
this inventory, mocked invariants, sanitized plan policy, cost assumptions, and affected runbook
together.
