# Architecture

This document is about what runs where in production, on Google Cloud. Everything runs in
`europe-west1`, and the database hosts in zone `europe-west1-d`.

## Projects

Production is split into four projects, one per trust zone, so each one holds only the access its
contents need. The services of a zone share its project. An organization holds a limited number of
Google Cloud projects, and raising that quota is slow. Services therefore keep apart through their
own identities, image repositories, network tags and database hosts.

| Project                   | Zone       | Holds                                                                               |
| ------------------------- | ---------- | ----------------------------------------------------------------------------------- |
| `a-novel-management-prod` | management | State bucket, backup buckets, secrets, CI identities. Survives a workload rebuild.  |
| `a-novel-production-prod` | private    | Shared VPC host, database and backup VMs, JSON Keys, GenAI, every job and schedule. |
| `a-novel-public-api-prod` | public-api | Authentication REST API, attached to the private VPC.                               |
| `a-novel-public-prod`     | public     | Reserved for platforms, with no VPC attachment and no database access.              |

## Network

- **VPC** `agora-production` has two subnets, no load balancer and no external IP on any VM:
  - `10.20.0.0/24` holds the VMs and the workloads that stay inside Google;
  - `10.20.1.0/25`, the egress subnet, holds the Direct VPC egress of the egress allowlist's
    workloads.
- **Internet egress** leaves through Cloud NAT, which serves the egress subnet alone, from one
  reserved address, `agora-production-nat`. Foundation's `nat_address` output gives it. A VPC-wide
  default route serves NAT, and NAT logs only its errors. OpenAI's project and the Workspace SMTP
  relay admit that address alone, so a new address joins both before it replaces the old one.
- **Google APIs** are reached through the restricted VIP ranges `199.36.153.4/30` and
  `34.126.0.0/18`. Private DNS zones resolve `googleapis.com`, `pkg.dev` and `run.app` to them.
- **Egress allowlist.** A network firewall policy, `agora-egress-allowlist`, runs before the firewall
  rules. It lets named identities reach named destinations, and nothing else:

  | Destination                                        | Identities                                                  |
  | -------------------------------------------------- | ----------------------------------------------------------- |
  | `api.openai.com:443`                               | `agora-genai-private`, `agora-genai-sweep`                  |
  | Google's service ranges on 587, for the SMTP relay | `agora-authentication-api`, `agora-authentication-maintain` |

  The firewall resolves a host name through the VPC's Cloud DNS and matches the addresses it
  returns, which works only when every client gets the same answer. `api.openai.com` gives everyone
  the same two Cloudflare addresses. `smtp-relay.gmail.com` answers each client location with another
  frontend, so SMTP matches the `google-services` address group instead: every range Google
  announces, minus those its Cloud customers rent. `refresh-google-ranges.yaml` proposes Google's
  latest list daily, and its pull request merges alone when it holds exactly what Google publishes.

  Other traffic falls through to the firewall rules. Direct VPC egress logs no firewall verdict, so
  a refused connection shows only as the caller's own error.

- **DNS allowlist.** A Cloud DNS response policy, `agora-dns-allowlist`, resolves only the private
  zones, Compute Engine's internal names and the egress allowlist's hosts. Every other name answers
  with a CNAME to `blocked.internal.`, which does not exist, so the lookup ends in NXDOMAIN and no
  outside name server receives it. A host added to the egress allowlist joins the DNS allowlist in
  the same entry.

- **DNS query logs.** The network logs every lookup to Cloud Logging as a `dns_query` entry, with
  its name, source address and answer.

- **Firewall.** A VPC-wide rule denies all egress at priority 1200. Explicit rules above it allow:

  | Traffic                                                                              | Priority |
  | ------------------------------------------------------------------------------------ | -------- |
  | PostgreSQL into each database host, from both subnets, on its own port               | 800      |
  | Each service's PostgreSQL egress, to its own database port only                      | 810      |
  | HTTPS egress to the Google API ranges, from the private workloads                    | 800      |
  | pgBackRest TLS on 8432, from a database host to its repository VM                    | 810      |
  | HTTPS egress to the Google API ranges, from each repository VM                       | 810      |
  | SSH from Identity-Aware Proxy, `35.235.240.0/20`, to the database and repository VMs | 810      |

- **JSON Keys gRPC** has internal ingress and IAM authentication. Only Authentication's API identity
  and JSON Keys' smoke identity may invoke it.
- **Authentication REST** has public ingress and IAM authentication, under the custom audience
  `agora-authentication-rest`. Only the platform and the health checks may invoke it, so it can
  trust the visitor IP the platform sends in `X-Client-IP`. Its egress and the maintenance job's go
  through the VPC from the egress subnet: SMTP leaves through Cloud NAT, and JSON Keys and the
  Telemetry API stay on the restricted VIP.
- **GenAI gRPC and sweep** have internal ingress and IAM authentication. GenAI's smoke identity
  invokes the gRPC service. Only the scheduler identity invokes the sweep. Their egress goes
  through the VPC from the egress subnet: OpenAI's API leaves through Cloud NAT, and the Telemetry
  API stays on the restricted VIP.
- **Invocation tags** (`agora-invocation`: `internal`, `maintenance`, `release`, `scheduled`) gate
  who may invoke each Cloud Run service or job. Only the named maintenance operators run the
  `maintenance` job, and only they may pass it arguments.
- **Organization policies** on `a-novel-production-prod` allow only internal ingress
  (`run.allowedIngress`) and require the invoker IAM check (`run.managed.requireInvokerIam`).
  Cloud Run refuses a deploy there that breaks either. Organization admins set both by hand, and no
  CI identity holds an organization role that could lift them. Public APIs run in
  `a-novel-public-api-prod`.
- **An organization deny policy** keeps `infra-plan` from reading logs and traces, which its Viewer
  role would otherwise cover. Pull requests can mint that identity. Organization admins set the
  policy by hand, from [the setup runbook](runbooks/setup.md#organization-guardrails).

## Services

| Service        | Cloud Run                                                                                                                                                                                                   | Jobs                                                                                                                                         |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| JSON Keys      | `agora-json-keys-grpc`: 1–2 instances, private ingress, CPU only during requests                                                                                                                            | `migrations` (runs at deploy), `rotatekeys` (Scheduler hourly at :10; the job keeps 24 h between rotations), `smoke` (probes each new image) |
| Authentication | `agora-authentication-rest`: 1 instance, which holds the in-memory rate limits; public ingress, CPU always allocated for detached mail                                                                      | `migrations` (runs at deploy, in the private project)                                                                                        |
| GenAI          | `agora-genai-grpc`: 0–4 instances, private ingress, CPU only during requests; `agora-genai-sweep`: 0–1 instance, private ingress, which Scheduler calls every minute to check the generations nobody polled | `migrations` (runs at deploy), `smoke` (probes each new image)                                                                               |

Service images come from `ghcr.io/a-novel/*`. Each is pinned as `tag@digest` in its service root's
`terraform.tfvars`, and each database image in foundation's `database_images` too. Every plan
verifies each release image it changes:

- the release tag's own run built it;
- the release App published that tag as an immutable GitHub Release;
- its version is not below the one deployed.

Before applying, the deploy copies the images to Artifact Registry. Artifact Registry holds two
repositories per service and zone, `…-production` and `…-tooling`, all with immutable tags. The
tooling repositories hold the [host tools](runbooks/host-tools.md), pinned by digest. A database
host reads only its service's private repositories: PostgreSQL from `…-production`, its host tools
from `…-tooling`. Foundation's shared `agora-production` repository receives no copies and has no
readers.

## Databases and backups

Each service has its own **database host**, sized in foundation's `database_capacity`. GenAI's rows
hold payloads and responses of up to 24 MiB, so its host is larger.

| Service        | Machine         | Container           | Connections | Address          |
| -------------- | --------------- | ------------------- | ----------- | ---------------- |
| JSON Keys      | `e2-medium`     | 0.75 vCPU, 1536 MiB | 50          | `10.20.0.5:5432` |
| Authentication | `e2-medium`     | 0.75 vCPU, 1536 MiB | 50          | `10.20.0.4:5433` |
| GenAI          | `e2-standard-2` | 1.5 vCPU, 6 GiB     | 150         | port `5434`      |

Each host combines:

- a Container-Optimized OS VM, the only member of a stateful instance group. Its COS image is
  pinned, and automatic OS updates are off;
- a 50 GiB `pd-balanced` data disk and a fixed IP, which both outlive the VM;
- PostgreSQL 18 from the service's `database` image, in a container held to the sizes above and
  supervised by systemd.

Each database has two login roles:

- `<database>` owns the database and is the cluster's superuser. It has no password and logs in
  only through the host's local socket;
- `<database>_app` owns schema `public` and holds no superuser, role or database rights. The
  services, their migrations and their jobs connect as this role.

At boot, the host removes the owner's password and sets the application role's. It then hands
`<database>_app` every object in `public` outside an extension, and GenAI's pg_cron jobs. Objects an
earlier superuser migration created change owner this way.

JSON Keys and Authentication have native backups. Each has its own **backup repository VM**, an
`e2-micro`: JSON Keys `10.20.0.6`, Authentication `10.20.0.7`. Foundation's
`native_backups.<service>.repository_ip` sets each address. The service root reserves it for the VM,
and the database host trusts it. GenAI has no native backups.

- The database host archives WAL and runs backups with pgBackRest, over mutual TLS, to its
  repository VM.
- The repository VM writes them to the management bucket `…-pgbr-<service>`. The bucket is
  versioned, refuses to delete an object younger than 7 days, and keeps deleted objects 7 more days.

| Schedule (UTC)        | Job                                |
| --------------------- | ---------------------------------- |
| Sunday 02:00          | full backup                        |
| Monday–Saturday 02:00 | differential backup                |
| hourly at :30         | archive check and TLS expiry check |

Each timer adds up to five minutes of random delay. pgBackRest keeps full backups, with the WAL and
differentials that depend on them, for 14 days. It owns their expiry, so the buckets never
age-delete live data. Restores go into a disposable project, as [Recovery](runbooks/recovery.md)
describes.

Before restarting a database host, each rollout snapshots its data disk into `europe-west1`. Each
rollout also deletes that service's snapshots older than 14 days, so a snapshot lasts at least that
long. They are recovery data, as
[Pre-rollout snapshots](runbooks/database.md#pre-rollout-snapshots) describes.

## Secrets

Secret containers live in the management project. Humans add their values with `gcloud`, as
[Secrets](runbooks/secrets.md) describes, so OpenTofu never sees them. Workloads read the numeric
version their root's `terraform.tfvars` pins.

| Secret                                                     | Read by                                                      |
| ---------------------------------------------------------- | ------------------------------------------------------------ |
| `production-json-keys-app-master-key`                      | JSON Keys runtime, rotation job                              |
| `production-authentication-waitlist-secret`                | Authentication API, when the waitlist is on                  |
| `production-genai-openai-api-key`                          | GenAI runtime and sweep                                      |
| `production-<service>-app-password`                        | Database host and database workloads                         |
| `production-<service>-pgbackrest-{ca,database,repository}` | Database host and repository VM (TLS)                        |
| `production-downtime-discord-webhook`                      | `downtime-announcer`, when it posts a planned downtime step  |
| `production-github-dispatch-{a-novel,a-novel-kit}`         | `github-dispatcher`, when it dispatches that org's workflows |

## Identities

| Account                                                                                                      | Purpose                                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `infra-plan`, `infra-foundation` (management)                                                                | CI: read-only plans and checks, and deployments.                                                                                                                               |
| `infra-downtime` (management)                                                                                | CI: starts and cancels the planned downtime announcements.                                                                                                                     |
| `infra-health` (management)                                                                                  | CI: the scheduled health check, which calls Authentication's REST API.                                                                                                         |
| `agora-json-keys-private`, `agora-authentication-private`, `agora-authentication-api`, `agora-genai-private` | Cloud Run runtimes, one per service and zone: the gRPC servers, Authentication's migrations and REST API.                                                                      |
| `agora-<service>-<role>`: `migrations`, `rotatekeys`, `sweep`, `smoke`, `maintain`                           | All the services' other workloads, each with its own account, which reads only the secrets that this workload mounts. The smoke identities may only invoke their gRPC service. |
| `agora-json-keys-database`, `agora-auth-database`, `agora-genai-database`                                    | Database hosts.                                                                                                                                                                |
| `agora-pgbr-<service>`                                                                                       | Backup repository VMs.                                                                                                                                                         |
| `pgbr-<service>-recovery` (management)                                                                       | Recovery drill hosts: read and restore backups, never delete. Disabled outside drills.                                                                                         |
| `agora-scheduler-invoker`                                                                                    | Runs the rotation job, and only jobs tagged `scheduled`; calls GenAI's sweep.                                                                                                  |
| `<slug>-visual-ci`, `<slug>-visual-maintenance` (management)                                                 | The CI of studio, template and a-novel-kit/uikit: visual-test evidence in Google Drive, no Cloud Storage access.                                                               |
| `downtime-announcer` (management)                                                                            | Runs the planned downtime announcements; reads only the Discord webhook.                                                                                                       |
| `github-dispatcher`, `github-dispatch-clock` (management)                                                    | The timed workflows' clock: starts the dispatcher, which reads only the dispatch tokens.                                                                                       |

Data Access audit logs are on in the management project for IAM, Secret Manager, Cloud Storage and
token exchange.

## State

All state lives in `a-novel-management-prod-232403541574-tofu-state`, one object per root, as
[State](runbooks/state.md) details.

## Monitoring

- **Alerts** email an operations channel: foundation's, or the service runtime's own. They cover
  Authentication's 5xx rate, GenAI's sweep failures, failed jobs and key rotation, database
  capacity, backups, and the [monthly budget](costs.md). [Alerts](runbooks/alerts.md) gives each
  threshold and what to do.
- **Health checks** call Authentication's `/v2/healthcheck` after each deploy and from `drift.yaml`,
  as [Authentication health](runbooks/alerts.md#authentication-health) details.
- **Logs** are kept 30 days. Successful health-check requests to Authentication and successful
  database health probes are not logged.
- **Traces and logs** leave the services over OTLP to Google's Telemetry API.
