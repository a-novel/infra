# Google Cloud provider guide

This guide explains how Agora uses Google Cloud and which security properties every provider resource
must preserve. It assumes the reader knows OpenTofu. Google Cloud product behavior is linked to its
official documentation instead of being redefined here.

`gcloud` is the Google Cloud CLI; Google Cloud is the provider. OpenTofu remains the source of truth
for durable managed resources. Operator-only CLI commands belong in runbooks when a manual
prerequisite or an independent verification cannot safely be automated. The one routine exception is
a fixed, tested group-metadata command in the protected release workflow; its committed
manifest and private receipt are the desired-state and rollback records.

## Current status

The bootstrap root now defines the resources inside a stable management project: protected EU state,
backup, and receipt buckets; managed-folder state boundaries; four keyless automation identities and
GitHub OIDC providers; exact IAM; nine metadata-only secret containers; required APIs; and targeted
Data Access audit logging. Merging the code creates nothing. The project, billing link, initial APIs,
private state-bucket seed and import, first apply, GitHub environment protection, optional
organization policies, and temporary-access removal remain explicit human bootstrap actions.

The foundation root now defines the replaceable workload project, required APIs, a custom VPC and
subnet, explicit restricted Google routes, firewall policy, private DNS, deprivileged default service
accounts, seven keyless runtime identities, exact management-secret access, an immutable registry, a
two-project production budget with current/forecast thresholds, separate cost and operations email
channels, bounded logging, a preserved balanced disk, and a one-member stateful managed instance
group for PostgreSQL. Its pinned COS template, startup/shutdown scripts, stateful private address,
operator access, release-metadata role, and eight alert policies have mocked
security tests but have not been applied. The same root defines separate create-only backup and
read-only restore identities, a daily seven-day `europe-west1` snapshot policy, and Cloud Scheduler
API activation. Recovery mode omits production alert/budget resources and grants Project Deleter
only inside the disposable project so reviewed cleanup cannot target production.

Foundation seeds seven empty non-secret database release keys in the MIG's all-instances
configuration and ignores later drift only on that field. A tested helper validates and patches those
seven keys after rejecting any unexpected map shape, requires a scheduled snapshot and fresh logical
backups, then caps the existing member's update at `RESTART`. The group is `OPPORTUNISTIC`, so no
metadata or template change acts on the existing member before the owning workflow explicitly
chooses `RESTART` or `REPLACE`.

OpenTofu owns the thirteen workload APIs declared by the foundation root. Service Usage can also
enable default services and dependencies, so the independent audit accepts only the reviewed
auxiliary set beside those thirteen and reports any new service by name. This keeps unexpected
products visible without trying to disable services Google manages on behalf of an enabled API. See
[Service Usage dependencies](https://cloud.google.com/service-usage/docs/overview#service_dependencies).

The release root now defines two four-hour backup jobs, two monthly clean restore jobs, one hourly
recovery monitor, and their authenticated schedules. It also defines four explicit application jobs,
hourly JSON Keys rotation, private JSON Keys gRPC with an exact invoker allowlist, and public
Authentication REST. A deploy-only role excludes job execution and overrides. Exact job IAM lets
release run migrations and key rotation, the scheduler run rotation, and named humans run
Authentication initialization. Every runtime scales to zero and remains absent while its atomic
release contract is disabled. The production manifest now selects both reviewed launch families,
but the protected release job remains disabled by a fail-safe repository switch until bootstrap and
the operator runbook are complete. After launch, a protected manifest merge starts the same fixed
release graph; manual dispatch remains for first activation, retry, and rollback. There is no load
balancer, public IP, NAT, connector, proxy, or Kubernetes layer.

## Provider and resource references

The [`hashicorp/google` provider reference](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
defines each resource's OpenTofu arguments. The Google Cloud links below explain the product behavior,
security model, operational limits, and recovery implications behind those arguments.

| Capability                                    | Owning root                                  | Agora usage                                                                                                                                                                                                                                                                              | Official Google Cloud documentation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------------------------------------- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Resource Manager projects                     | Bootstrap and foundation                     | Keep the recovery plane stable while allowing a workload project to be rebuilt; one exact protected workflow can later delete only a committed disposable recovery project.                                                                                                              | [Creating and managing projects](https://cloud.google.com/resource-manager/docs/creating-managing-projects), [project IAM roles](https://cloud.google.com/resource-manager/docs/access-control-proj)                                                                                                                                                                                                                                                                                                                                                                            |
| Cloud Storage                                 | Bootstrap                                    | Store state, reviewed plans, release receipts, logical backups, and recovery records with separate prefixes and IAM.                                                                                                                                                                     | [Cloud Storage overview](https://cloud.google.com/storage/docs/introduction), [public access prevention](https://cloud.google.com/storage/docs/public-access-prevention), and [Object Versioning](https://cloud.google.com/storage/docs/object-versioning)                                                                                                                                                                                                                                                                                                                      |
| IAM and Workload Identity Federation          | Bootstrap and foundation                     | Give GitHub and workloads short-lived, use-specific identities without keys, and remove basic roles from default accounts.                                                                                                                                                               | [Workload Identity Federation for deployment pipelines](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines), [WIF practices](https://cloud.google.com/iam/docs/best-practices-for-using-workload-identity-federation), [service-account practices](https://cloud.google.com/iam/docs/best-practices-service-accounts), and [Compute Engine service accounts](https://cloud.google.com/compute/docs/access/service-accounts)                                                                                                               |
| Secret Manager                                | Bootstrap                                    | Manage secret metadata and exact-version access in code while operators supply payload versions.                                                                                                                                                                                         | [Secret Manager overview](https://cloud.google.com/secret-manager/docs/overview), [best practices](https://cloud.google.com/secret-manager/docs/best-practices), and [rotation recommendations](https://cloud.google.com/secret-manager/docs/rotation-recommendations)                                                                                                                                                                                                                                                                                                          |
| VPC, subnet, DNS, and firewall rules          | Foundation                                   | Carry private service and database traffic, restricted Google API access, and explicit egress profiles.                                                                                                                                                                                  | [VPC overview](https://cloud.google.com/vpc/docs/vpc), [firewall rules](https://cloud.google.com/firewall/docs/firewalls), [Private Google Access](https://cloud.google.com/vpc/docs/configure-private-google-access), and [Cloud DNS private zones](https://cloud.google.com/dns/docs/zones/zones-overview)                                                                                                                                                                                                                                                                    |
| Artifact Registry                             | Foundation and release                       | Hold the regional copy of a verified GHCR digest and retain every image named by a recovery receipt.                                                                                                                                                                                     | [Container image names](https://cloud.google.com/artifact-registry/docs/docker/names) and [cleanup policies](https://cloud.google.com/artifact-registry/docs/repositories/cleanup-policy-overview)                                                                                                                                                                                                                                                                                                                                                                              |
| Cloud Run services and jobs                   | Release                                      | Run scale-to-zero HTTP/gRPC services and explicit migration, initialization, rotation, backup, and restore jobs.                                                                                                                                                                         | [Cloud Run overview](https://cloud.google.com/run/docs/overview/what-is-cloud-run), [jobs](https://cloud.google.com/run/docs/create-jobs), and [end-to-end HTTP/2](https://cloud.google.com/run/docs/configuring/http2)                                                                                                                                                                                                                                                                                                                                                         |
| Direct VPC egress                             | Foundation and release                       | Give Cloud Run revisions private addresses and apply workload-specific VPC firewall policy without a connector.                                                                                                                                                                          | [Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc) and [private Cloud Run networking](https://cloud.google.com/run/docs/securing/private-networking)                                                                                                                                                                                                                                                                                                                                                                                             |
| Compute Engine, stateful MIG, and Shielded VM | Foundation plus protected release deployment | Keep one named, private COS database VM replaceable while preserving its address and disk; update only seven group-level release fields during routine deployment.                                                                                                                       | [Stateful MIGs](https://cloud.google.com/compute/docs/instance-groups/configuring-stateful-migs), [all-instances configuration](https://cloud.google.com/compute/docs/instance-groups/set-mig-aic), [apply updates](https://cloud.google.com/compute/docs/instance-groups/rolling-out-updates-to-managed-instance-groups), [preserved state](https://cloud.google.com/compute/docs/instance-groups/preserved-state), [Container-Optimized OS](https://cloud.google.com/container-optimized-os/docs), and [Shielded VM](https://cloud.google.com/compute/docs/about-shielded-vm) |
| Persistent Disk and snapshots                 | Foundation                                   | Keep database data independent from the replaceable VM and retain one globally scoped crash-consistent disk snapshot per day for seven days, with its data stored in the workload region.                                                                                                | [Persistent Disk](https://cloud.google.com/compute/docs/disks/persistent-disks), [stateful disks](https://cloud.google.com/compute/docs/instance-groups/configuring-stateful-migs), [snapshot schedules](https://cloud.google.com/compute/docs/disks/about-snapshot-schedules), [snapshot storage locations](https://cloud.google.com/compute/docs/disks/snapshots#storage_location), [snapshot practices](https://cloud.google.com/compute/docs/disks/snapshot-best-practices), and [snapshot pricing](https://cloud.google.com/compute/disks-image-pricing#disk)              |
| Cloud Scheduler                               | Release                                      | Start recurring key-rotation, backup, clean-restore, and recovery-monitor jobs without an always-running scheduler container.                                                                                                                                                            | [Cloud Scheduler overview](https://cloud.google.com/scheduler/docs/overview), [scheduled Cloud Run jobs](https://cloud.google.com/run/docs/execute/jobs-on-schedule), [authenticated HTTP targets](https://cloud.google.com/scheduler/docs/http-target-auth)                                                                                                                                                                                                                                                                                                                    |
| Cloud Monitoring and Logging                  | Foundation                                   | Use native Cloud Run/Compute metrics, eight actionable policies, two human email channels, current/forecast budget thresholds, and bounded payload-free logs without another agent or controller. The existing GitHub drift workflow performs the low-frequency public dependency check. | [Alerting overview](https://cloud.google.com/monitoring/alerts), [Cloud Run metrics](https://cloud.google.com/monitoring/api/metrics_gcp_p_z#gcp-run), [notification channels](https://cloud.google.com/monitoring/support/notification-options), [Monitoring pricing](https://cloud.google.com/products/observability/pricing), [Cloud Logging overview](https://cloud.google.com/logging/docs/overview), and [scheduled workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)                                 |

Each root README lists its actual OpenTofu resource addresses. An inventory entry explains the
resource's Agora purpose, access and data boundary, replacement or deletion behavior, cost and
recovery impact, and links both the pinned provider resource page and the relevant Google Cloud
product page. The [bootstrap inventory](../bootstrap/README.md#resource-inventory) and
[foundation inventory](../environments/production/foundation/README.md#resource-inventory) are the
concrete implementations of that contract.

## Network trust model

```text
Internet
   |
   | HTTPS
   v
Authentication Cloud Run service (public ingress, application authorization)
   |
   | VPC-routed gRPC + Google-signed ID token
   v
JSON Keys Cloud Run service (internal ingress, IAM allowlist)

Cloud Run service and backup-job identities
   |
   | Direct VPC egress + tagged allows on TCP 5432/5433
   v
PostgreSQL containers on a VM internal address (no external IP or public frontend)

Restore and backup-monitor jobs
   |
   `-- restricted Google APIs only; no PostgreSQL route or public internet

Operator debug paths
   |-- IAM-authenticated Cloud Run developer proxy
   `-- IAP TCP forwarding to the VM internal address
```

Network location never grants application authority by itself. Private gRPC requires both an internal
network path and a Google-signed caller identity. PostgreSQL combines an internal-only address,
targeted firewall access, database credentials, and service-owned database roles.

## PostgreSQL isolation target

The database host has no external IP, public load balancer, forwarding rule, public DNS record, or
public firewall path. JSON Keys publishes only TCP `5432` and Authentication only TCP `5433` on
the VM's stateful internal address. Ingress accepts the production subnet and targets only the
database-host network tag. Approved revisions and jobs carry caller-specific tags: JSON Keys can
egress only to `5432`, Authentication only to `5433`, and backup jobs to both. Restore jobs have no
database egress route. Each database
keeps its own cluster, data directory, credentials, and role boundary.

Google supports Direct VPC tags as firewall targets for Cloud Run egress, but not as source tags in
ingress rules. The subnet source range is therefore intentional, not a substitute for caller
authorization. Tagged egress, service-specific database credentials, PostgreSQL roles, and the
database target tag form the remaining layers. See Google's
[Direct VPC network-tag limitations](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc#network-tags).

The foundation tests must prove that:

- the VM network interface has no external access configuration;
- no ingress rule permits `0.0.0.0/0` or `::/0` to a database target;
- TCP `5432` and `5433` ingress target only the database host and accept only the production
  subnet;
- private callers receive only their reviewed egress tag, database credential, and database role;
- no external load-balancing or public DNS resource targets the host;
- the preserved data disk and internal address survive boot-VM replacement;
- the one-member group has no autoscaler or health-based repair loop;
- administrative TCP access uses OS Login through IAP and an explicit operator identity.

The VM uses a named COS image with automatic in-place OS updates explicitly disabled. A reviewed
foundation change creates a new immutable template and updates the group's target, but the
`OPPORTUNISTIC` policy does not act on the member. The protected foundation workflow must then
explicitly cap its rollout at `REPLACE` under the group's `RECREATE` policy: both containers stop,
the single boot VM is recreated with the same name, disk, and address, and both databases converge.
This has a planned outage. The workflow and operator runbook own application readiness and rollback
because automatic repair could loop on a damaged stateful disk.

The two PostgreSQL containers use separate, fixed Docker bridge subnets. Port publishing needs a
normal bridge; Docker's `--internal` mode would also block the required private inbound path. Two
host firewall chains allow established replies and reject every connection initiated from either
container subnet. A loopback-only DNS setting prevents Docker's embedded resolver from becoming a
separate egress path. The containers therefore cannot call the peer database, host, metadata server,
VPC workloads, Google APIs, or internet while approved clients can use the published private ports.

The startup script reads only exact numeric owner and backup password versions with the database runtime identity.
Payloads are root-owned files under `/run`, mounted read-only, and referenced through
`POSTGRES_PASSWORD_FILE`. Each password must be a distinct 32–128 character URL-safe value. PostgreSQL
local-socket trust is confined to each container. A local superuser session reads the mounted file,
quotes the value inside the server, and stores its SCRAM verifier. That session explicitly disables
statement, duration, sampling, audit, and error logging; all client output is discarded, and failure
reports only a fixed category. TCP authentication remains SCRAM-SHA-256. The payload never crosses
the Docker exec stream or enters client SQL, instance metadata, Docker configuration, process
arguments, environment variables, server logs, OpenTofu state, or release output. The final files
remain only as read-only bind sources for healthy crash restart; failed or disabled convergence
removes them, and reboot clears `/run`.

Launch uses Google Cloud's authenticated, integrity-protected, encrypted private-IP VPC transport
instead of adding a PostgreSQL certificate authority that this team would have to issue, rotate,
and recover. The DSNs therefore use `sslmode=disable` only inside this one private network, with
SCRAM providing database authentication. An external, hybrid, or differently trusted network path
requires a reviewed PostgreSQL TLS design and coordinated DSN rotation first. See
[encryption in transit inside Google's virtual network](https://cloud.google.com/docs/security/encryption-in-transit#google_cloud_virtual_network_authentication_and_encryption).

This foundation deliberately provisions no Cloud NAT, router, or Serverless VPC Access connector.
Private-only workloads consequently have no public VPC egress path. Adding one later is an
architecture and cost change, not an operational toggle, and must preserve the no-external-IP and
firewall properties above.

Debug access does not weaken the production path. The runbook will use
[IAP TCP forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding) to the VM's internal
address after IAM authorization. OS Login requires the operator to hold OS Admin Login, Compute
Viewer, IAP Tunnel Resource Accessor limited to port `22`, and Service Account User on the exact
database runtime identity. The last role supplies the required `actAs` check and does not mint
tokens by itself. An operator with root shell access can still use the VM's runtime identity, so this
access is reserved for named humans and treated as privileged. Debugging never creates a temporary
public IP or public PostgreSQL rule. See Google's
[OS Login role requirements](https://cloud.google.com/compute/docs/oslogin/set-up-oslogin).

## Private gRPC target

JSON Keys is a server, so it cannot be literally outbound-only: it must accept RPCs from approved
internal workloads to provide a service. The contract is that no public or unauthenticated client can
invoke it.

The service uses Cloud Run `internal` ingress and end-to-end HTTP/2. Foundation grants
`roles/run.servicesInvoker` to Authentication only when the target carries the permanent `internal`
Resource Manager tag. Release can attach that value but cannot change the conditional IAM policy;
recovery uses only control-plane readiness inspection in production. The policy grants neither
`allUsers` nor `allAuthenticatedUsers`, and it has no external load balancer or public custom domain. Google
recommends combining
[Cloud Run ingress restrictions](https://cloud.google.com/run/docs/securing/ingress) with
[service-to-service IAM authentication](https://cloud.google.com/run/docs/authenticating/service-to-service)
as separate network and identity layers.

The foundation and release tests must prove that:

- ingress is exactly `internal`;
- the service has the exact `internal` tag and conditional invoker allowlist, with no public principal;
- the service uses its dedicated runtime identity;
- end-to-end HTTP/2 is enabled for gRPC;
- approved callers route the `run.app` destination through the production VPC using Private Google
  Access and private DNS;
- an unauthenticated request and an authenticated external-network request both fail;
- an authenticated request from an approved internal workload succeeds.

Human private-path debugging originates from the existing database VM through IAP and uses a named
operator plus an exact service identity. The service does not open public ingress or add a proxy for
debugging. See the [disaster-recovery runbook](./runbooks/disaster-recovery.md#6-verify-functionality-from-the-private-replacement-network).

## Job execution boundaries

Cloud Run jobs have no request ingress, but execution is still an IAM permission. The release identity
uses a custom deployment role that contains the job/service lifecycle and tag-binding permissions
required by the provider and omits execution, overrides, and IAM-policy access. Foundation owns
project-level conditional `roles/run.jobsExecutor` or `roles/run.servicesInvoker` grants. They become
effective only on Cloud Run resources carrying one exact permanent Resource Manager tag. Using the
separate standard roles prevents a job operator from invoking services and a service caller from
executing jobs. Google documents
[tag-based IAM conditions](https://cloud.google.com/iam/docs/conditions-resource-attributes#resource_tags),
[Cloud Run tags](https://cloud.google.com/run/docs/configuring/jobs/tags), and execution permissions
separately in the [Cloud Run IAM role](https://cloud.google.com/run/docs/reference/iam/roles) and
[job execution](https://cloud.google.com/run/docs/execute/jobs) references.

Release can attach and invoke `release` and `scheduled` jobs. The scheduler identity can invoke only
`scheduled` jobs. It cannot update a job, access a secret, or connect to a database as itself; Cloud
Run starts each job as that job's runtime identity. Authentication can invoke only the `internal`
private service. Recovery automation and the private smoke caller are confined to `recovery` targets
in a disposable project.

Authentication initialization can reset the first administrator's password and raise that account to
the super-admin role. Only named `user:` or `group:` members receive the initializer tag value,
conditional invoker, narrow job deployer, initializer `actAs`, and registry read. The release identity
has none of those capabilities and cannot read/change Cloud Run IAM. The human creates an inert job,
attaches and verifies the initializer tag, then adds the exact secret references and executes without
overrides. Its dedicated runtime identity reads only the Authentication DSN and bootstrap password,
which keeps the REST identity from reading the bootstrap credential. The human deletes the job after
the immutable success marker exists.

JSON Keys defines a 24-hour shortest key-rotation interval. The release workflow runs the idempotent
rotation job after migration to seed a new database, and Cloud Scheduler evaluates it hourly after
that. The hourly schedule bounds normal rotation delay below one hour while every unused execution
scales back to zero.

## Egress profiles

Ingress controls who can call a service. Egress controls what that service can call. A private gRPC
service can therefore accept only approved internal RPCs while still reaching an external API through
a separately reviewed egress profile.

| Profile      | Direct VPC setting    | Public internet path                                                                                                                                                       | Initial workloads                                                        |
| ------------ | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Private-only | `all-traffic`         | None. The VPC has no Cloud NAT; restricted Private Google Access supplies supported Google APIs.                                                                           | JSON Keys, database backup jobs, and read-only restore/monitor jobs.     |
| Public TLS   | `private-ranges-only` | Public destinations use Cloud Run's managed egress; private addresses and the restricted `run.app` VIP use the VPC. TLS and application credentials authorize public APIs. | Authentication for SMTP and a future private GenAI service for LLM APIs. |
| No ingress   | Workload-specific     | Determined by either profile above.                                                                                                                                        | Cloud Run Jobs, which expose no request endpoint.                        |

The private-only profile routes all traffic into the VPC, applies egress firewall policy, and has no
NAT route to the public internet. Restricted Private Google Access lets those workloads reach
required Google APIs without a public workload address and rejects APIs unsupported by VPC Service
Controls. No VPC Service Controls perimeter exists at this scale, so the restricted VIP narrows API
egress without creating a project data boundary. The public-TLS profile does not make a service
publicly callable; its ingress and IAM remain independent.

Authentication uses the public-TLS profile because it must call external SMTP while also invoking
private JSON Keys. Private Google Access and a private DNS zone resolve `run.app` to Google's
restricted VIP, so the gRPC request traverses the VPC and satisfies internal ingress. Public
destinations continue through Cloud Run's managed egress. This avoids a permanently billed connector, NAT gateway,
Private Service Connect endpoint, or internal load balancer at the current scale. Managed public
egress is not a domain allowlist; TLS verification, narrow application credentials, secret handling,
and application policy remain mandatory for SMTP and future LLM calls.

Google defines the two routing modes in the
[Direct VPC egress documentation](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc).
Private Cloud Run-to-Cloud Run traffic follows Google's
[private networking requirements](https://cloud.google.com/run/docs/securing/private-networking),
including VPC routing and private `run.app` DNS. Google's
[Cloud Run networking practices](https://cloud.google.com/run/docs/configuring/networking-best-practices)
document this private-DNS pattern and the scale-to-zero cost advantage of Direct VPC egress.

## Verification contract

Every Google Cloud resource pull request adds four kinds of evidence before it can apply:

1. The owning root README records the exact resource and links its provider and product references.
2. Native mocked tests assert its access, exposure, lifecycle, and deletion invariants.
3. Static validation rejects unsafe configuration, and the sanitized plan policy blocks destruction
   of every managed resource.
4. A runbook defines the operator command, expected non-secret output, independent verification, and
   recovery path.

Post-apply checks query the deployed control plane and exercise both an allowed and a denied path.
Exact commands use validated shell variables only where Google requires an operator-selected global
identifier, billing account, parent, reviewer, generation, or secret. Every variable is introduced
and checked before use; unexplained placeholders are forbidden. Agents provide commands for operators
and wait for their sanitized result. Agents never run `gcloud`.
