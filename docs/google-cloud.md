# Google Cloud provider guide

This guide explains how Agora uses Google Cloud and which security properties every provider resource
must preserve. It assumes the reader knows OpenTofu. Google Cloud product behavior is linked to its
official documentation instead of being redefined here.

`gcloud` is the Google Cloud CLI; Google Cloud is the provider. OpenTofu remains the source of truth
for managed resources. Operator-only CLI commands belong in runbooks when a manual prerequisite or an
independent verification cannot safely be automated.

## Current status

The repository currently declares the Google provider and an unconfigured GCS backend in three roots.
It contains no Google Cloud `resource` blocks. No project, network, firewall, Cloud Run service, VM,
disk, bucket, secret, or IAM binding exists because of this repository yet.

The sections below are acceptance contracts for the resource pull requests that follow. A statement
marked as a target becomes an enforced property only when the corresponding OpenTofu resource, mocked
test, protected deployment, and post-apply verification have landed.

## Provider and resource references

The [`hashicorp/google` provider reference](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
defines each resource's OpenTofu arguments. The Google Cloud links below explain the product behavior,
security model, operational limits, and recovery implications behind those arguments.

| Capability                           | Owning root              | Agora usage                                                                                                              | Official Google Cloud documentation                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------ | ------------------------ | ------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Resource Manager projects            | Bootstrap and foundation | Keep the recovery plane stable while allowing the workload project to be rebuilt.                                        | [Creating and managing projects](https://cloud.google.com/resource-manager/docs/creating-managing-projects)                                                                                                                                                                                                                                                     |
| Cloud Storage                        | Bootstrap                | Store state, reviewed plans, release receipts, logical backups, and recovery records with separate prefixes and IAM.     | [Cloud Storage overview](https://cloud.google.com/storage/docs/introduction), [public access prevention](https://cloud.google.com/storage/docs/public-access-prevention), and [Object Versioning](https://cloud.google.com/storage/docs/object-versioning)                                                                                                      |
| IAM and Workload Identity Federation | Bootstrap and foundation | Give GitHub and workloads short-lived, use-specific identities without service-account keys.                             | [Workload Identity Federation for deployment pipelines](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines), [WIF practices](https://cloud.google.com/iam/docs/best-practices-for-using-workload-identity-federation), and [service-account practices](https://cloud.google.com/iam/docs/best-practices-service-accounts) |
| Secret Manager                       | Bootstrap                | Manage secret metadata and exact-version access in code while operators supply payload versions.                         | [Secret Manager overview](https://cloud.google.com/secret-manager/docs/overview), [best practices](https://cloud.google.com/secret-manager/docs/best-practices), and [rotation recommendations](https://cloud.google.com/secret-manager/docs/rotation-recommendations)                                                                                          |
| VPC, subnet, DNS, and firewall rules | Foundation               | Carry private service and database traffic, private Google API access, and explicit egress profiles.                     | [VPC overview](https://cloud.google.com/vpc/docs/vpc), [firewall rules](https://cloud.google.com/firewall/docs/firewalls), [Private Google Access](https://cloud.google.com/vpc/docs/private-google-access), and [Cloud DNS private zones](https://cloud.google.com/dns/docs/zones/zones-overview)                                                              |
| Artifact Registry                    | Foundation and release   | Hold the regional copy of a verified GHCR digest and retain every image named by a recovery receipt.                     | [Container image names](https://cloud.google.com/artifact-registry/docs/docker/names) and [cleanup policies](https://cloud.google.com/artifact-registry/docs/repositories/cleanup-policy-overview)                                                                                                                                                              |
| Cloud Run services and jobs          | Foundation and release   | Run scale-to-zero HTTP/gRPC services and explicit migration, initialization, rotation, backup, and restore jobs.         | [Cloud Run overview](https://cloud.google.com/run/docs/overview/what-is-cloud-run), [jobs](https://cloud.google.com/run/docs/create-jobs), and [end-to-end HTTP/2](https://cloud.google.com/run/docs/configuring/http2)                                                                                                                                         |
| Direct VPC egress                    | Foundation and release   | Give Cloud Run revisions private addresses and apply workload-specific VPC firewall policy without a connector.          | [Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc) and [private Cloud Run networking](https://cloud.google.com/run/docs/securing/private-networking)                                                                                                                                                                             |
| Compute Engine and Shielded VM       | Foundation               | Run the always-on Container-Optimized OS database host without a public interface.                                       | [Compute Engine IP addresses](https://cloud.google.com/compute/docs/ip-addresses), [Container-Optimized OS](https://cloud.google.com/container-optimized-os/docs), and [Shielded VM](https://cloud.google.com/compute/docs/about-shielded-vm)                                                                                                                   |
| Persistent Disk and snapshots        | Foundation               | Keep database data independent from the replaceable VM and provide crash-consistent recovery points.                     | [Persistent Disk](https://cloud.google.com/compute/docs/disks/persistent-disks), [snapshot schedules](https://cloud.google.com/compute/docs/disks/about-snapshot-schedules), and [snapshot practices](https://cloud.google.com/compute/docs/disks/snapshot-best-practices)                                                                                      |
| Cloud Scheduler                      | Foundation               | Start recurring backup and restore-check jobs without an always-running scheduler container.                             | [Cloud Scheduler overview](https://cloud.google.com/scheduler/docs/overview)                                                                                                                                                                                                                                                                                    |
| Cloud Monitoring and Logging         | Foundation               | Alert on service, VM, database, backup, deployment, and budget symptoms while keeping logs bounded and free of payloads. | [Alerting overview](https://cloud.google.com/monitoring/alerts) and [Cloud Logging overview](https://cloud.google.com/logging/docs/overview)                                                                                                                                                                                                                    |

Each root README lists actual OpenTofu resource addresses once they exist. An inventory entry explains
the resource's Agora purpose, access and data boundary, replacement or deletion behavior, cost and
recovery impact, and links both the provider resource page and the relevant Google Cloud product page.

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

Cloud Run service and job identities
   |
   | Direct VPC egress + firewall allow on TCP 5432
   v
PostgreSQL containers on a VM internal address (no external IP or public frontend)

Operator debug paths
   |-- IAM-authenticated Cloud Run developer proxy
   `-- IAP TCP forwarding to the VM internal address
```

Network location never grants application authority by itself. Private gRPC requires both an internal
network path and a Google-signed caller identity. PostgreSQL combines an internal-only address,
targeted firewall access, database credentials, and service-owned database roles.

## PostgreSQL isolation target

The database host has no external IP, public load balancer, forwarding rule, public DNS record, or
public firewall path. Its PostgreSQL port is reachable only through the production VPC from Cloud Run service
revisions and job executions that carry an approved, workload-specific network tag. Containers publish
PostgreSQL on the VM's internal interface, and each database keeps its own cluster, data directory, credentials, and
role boundary.

The foundation tests must prove that:

- the VM network interface has no external access configuration;
- no ingress rule permits `0.0.0.0/0` or `::/0` to a database target;
- TCP `5432` ingress targets only the database host and accepts only approved source network tags;
- no external load-balancing or public DNS resource targets the host;
- the preserved data disk has deletion protection independent from VM replacement;
- administrative TCP access uses IAP and an explicit operator identity.

Google documents the outbound-only nature of NAT separately: [Public NAT permits established
responses but not unsolicited inbound requests](https://cloud.google.com/nat/docs/public-nat). Agora
does not rely on NAT for database isolation; the no-external-IP and firewall properties hold even if
NAT is added later for controlled outbound traffic.

Debug access does not weaken the production path. The runbook will use
[IAP TCP forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding) to the VM's internal
address after IAM authorization. It will not create a temporary public IP or public PostgreSQL rule.

## Private gRPC target

JSON Keys is a server, so it cannot be literally outbound-only: it must accept RPCs from approved
internal workloads to provide a service. The contract is that no public or unauthenticated client can
invoke it.

The service uses Cloud Run `internal` ingress and end-to-end HTTP/2. Its IAM policy grants
`roles/run.invoker` only to the Authentication runtime identity and the protected smoke/recovery
identity. It grants neither `allUsers` nor `allAuthenticatedUsers`, and it has no external load
balancer or public custom domain. Google recommends combining
[Cloud Run ingress restrictions](https://cloud.google.com/run/docs/securing/ingress) with
[service-to-service IAM authentication](https://cloud.google.com/run/docs/authenticating/service-to-service)
as separate network and identity layers.

The foundation and release tests must prove that:

- ingress is exactly `internal`;
- IAM has the exact invoker allowlist and contains no public principal;
- the service uses its dedicated runtime identity;
- end-to-end HTTP/2 is enabled for gRPC;
- approved callers route the `run.app` destination through the production VPC using Private Google
  Access and private DNS;
- an unauthenticated request and an authenticated external-network request both fail;
- an authenticated request from an approved internal workload succeeds.

Human debugging uses the
[authenticated Cloud Run developer proxy](https://cloud.google.com/run/docs/authenticating/developers)
with an explicitly granted operator identity. The service does not open public ingress for debugging.

## Egress profiles

Ingress controls who can call a service. Egress controls what that service can call. A private gRPC
service can therefore accept only approved internal RPCs while still reaching an external API through
a separately reviewed egress profile.

| Profile      | Direct VPC setting    | Public internet path                                                                                                                                                    | Initial workloads                                                        |
| ------------ | --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Private-only | `all-traffic`         | None. The VPC has no Cloud NAT for this profile; Private Google Access supplies supported Google APIs.                                                                  | JSON Keys and jobs that need only PostgreSQL or Google APIs.             |
| Public TLS   | `private-ranges-only` | Public destinations use Cloud Run's managed egress; private addresses and the private `run.app` VIP use the VPC. TLS and application credentials authorize public APIs. | Authentication for SMTP and a future private GenAI service for LLM APIs. |
| No ingress   | Workload-specific     | Determined by either profile above.                                                                                                                                     | Cloud Run Jobs, which expose no request endpoint.                        |

The private-only profile routes all traffic into the VPC, applies egress firewall policy, and has no
NAT route to the public internet. Private Google Access lets those workloads reach required Google
APIs without a public workload address. The public-TLS profile does not make a service publicly
callable; its ingress and IAM remain independent.

Authentication uses the public-TLS profile because it must call external SMTP while also invoking
private JSON Keys. Private Google Access and a private DNS zone resolve `run.app` to Google's private
VIP, so the gRPC request traverses the VPC and satisfies internal ingress. Other public destinations
continue through Cloud Run's managed egress. This avoids a permanently billed connector, NAT gateway,
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
3. Static validation and the sanitized plan policy reject unsafe configuration or protected
   destruction.
4. A runbook defines the operator command, expected non-secret output, independent verification, and
   recovery path.

Post-apply checks query the deployed control plane and exercise both an allowed and a denied path.
Exact commands are added only when project, resource, and identity names exist; placeholder commands
are too easy to run against the wrong target. Agents provide commands for operators and wait for their
sanitized result. Agents never run `gcloud`.
