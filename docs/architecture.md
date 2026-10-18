# Architecture

This document describes what runs where in production, on Google Cloud: projects, network,
services, databases and backups, secrets, identities, state and monitoring. Everything runs in
`europe-west1`, and the database hosts in zone `europe-west1-d`.

## Projects

Production is split into four projects, one per trust zone, so each one holds only the access its
contents need. The services of a zone share its project. An organization holds a limited number of
Google Cloud projects, and raising that quota is slow. Services therefore keep apart through their own
identities, image repositories, network tags and database hosts.

| Project                   | Zone       | Holds                                                                               |
| ------------------------- | ---------- | ----------------------------------------------------------------------------------- |
| `a-novel-management-prod` | management | State bucket, backup buckets, secrets, CI identities. Survives a workload rebuild.  |
| `a-novel-production-prod` | private    | Shared VPC host, database and backup VMs, JSON Keys, GenAI, every job and schedule. |
| `a-novel-public-api-prod` | public-api | Authentication REST API, attached to the private VPC.                               |
| `a-novel-public-prod`     | public     | Reserved for platforms; no VPC attachment, no database access.                      |

## Network

- **VPC** `agora-production` has one subnet, `10.20.0.0/24`, and no default internet route, NAT
  gateway, router, load balancer or external IP.
- **Google APIs** are reached through the restricted VIP ranges `199.36.153.4/30` and
  `34.126.0.0/18`. Private DNS zones resolve `googleapis.com`, `pkg.dev` and `run.app` to them.
- **Firewall.** A VPC-wide rule denies all egress at priority 1200. Explicit rules allow, above it:

  | Traffic                                                                              | Priority |
  | ------------------------------------------------------------------------------------ | -------- |
  | PostgreSQL into each database host, from the subnet, on its own port                 | 800      |
  | Each service's PostgreSQL egress, to its own database port only                      | 810      |
  | HTTPS egress to the Google API ranges, from the private workloads                    | 800      |
  | pgBackRest TLS on 8432, from a database host to its repository VM                    | 810      |
  | HTTPS egress to the Google API ranges, from each repository VM                       | 810      |
  | SSH from Identity-Aware Proxy, `35.235.240.0/20`, to the database and repository VMs | 810      |

- **JSON Keys gRPC** has internal ingress and IAM authentication. Only Authentication's API identity
  and JSON Keys' smoke identity may invoke it.
- **Authentication REST** has public ingress and IAM authentication, under the custom audience
  `agora-authentication-rest`. Only the platform and the health checks may invoke it. It therefore
  trusts the visitor IP the platform sends in `X-Client-IP`. Its egress reaches private ranges
  through the VPC, and SMTP through Google's managed egress.
- **GenAI gRPC and sweep** have internal ingress and IAM authentication. GenAI's smoke identity
  invokes the gRPC service. Only the scheduler identity invokes the sweep. Their egress reaches
  private ranges through the VPC, and OpenAI through Google's managed egress.
- **Invocation tags** (`agora-invocation`: `initializer`, `internal`, `release`, `scheduled`) gate
  who may invoke each Cloud Run service or job.
- **Organization policies** on `a-novel-production-prod` allow only internal ingress
  (`run.allowedIngress`) and require the invoker IAM check (`run.managed.requireInvokerIam`).
  Cloud Run refuses a deploy there that breaks either. Organization admins set both by hand, and no
  CI identity holds an organization role that could lift them. Public APIs run in
  `a-novel-public-api-prod`.
- **An organization deny policy** keeps `infra-plan` from reading logs and traces, though its Viewer
  role covers them. Pull requests can mint that identity. Organization admins set the policy by hand,
  from [the setup runbook](runbooks/setup.md#organization-guardrails).

## Services

| Service        | Cloud Run                                                                                                                                                                                                   | Jobs                                                                                                                                         |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| JSON Keys      | `agora-json-keys-grpc`: 1–2 instances, private ingress, CPU only during requests                                                                                                                            | `migrations` (runs at deploy), `rotatekeys` (Scheduler hourly at :10; the job keeps 24 h between rotations), `smoke` (probes each new image) |
| Authentication | `agora-authentication-rest`: 1 instance, which holds the in-memory rate limits; public ingress, CPU always allocated for detached mail                                                                      | `migrations` (runs at deploy, in the private project)                                                                                        |
| GenAI          | `agora-genai-grpc`: 0–4 instances, private ingress, CPU only during requests; `agora-genai-sweep`: 0–1 instance, private ingress, which Scheduler calls every minute to check the generations nobody polled | `migrations` (runs at deploy), `smoke` (probes each new image)                                                                               |

Service images come from `ghcr.io/a-novel/*`. Each is pinned as `tag@digest` in the service root's
`terraform.tfvars`, and its database image in foundation's too. Every plan verifies each image it
changes: its release tag's own run built it, the release App published that tag as an immutable
GitHub Release, and its version is not below the one deployed. Before applying, deploy copies the
images to Artifact Registry.

Artifact Registry holds `agora-production`, for the database images, and two repositories per
service and zone, `…-production` and `…-tooling`, all with immutable tags. The tooling repositories
hold the [host tools](runbooks/host-tools.md), pinned by digest.

## Databases and backups

Each service has its own **database host**, sized on its own in foundation's `database_capacity`:
machine type, container vCPU and memory, connection ceiling and data disk. JSON Keys and
Authentication run the sizes below. GenAI's rows hold payloads and responses of up to 24 MiB, so its
host is an `e2-standard-2` with a 1.5 vCPU, 6 GiB container and 150 connections.

- a Container-Optimized OS VM, `e2-medium`, the only member of a stateful instance group. Its COS
  image is pinned, and automatic OS updates are off;
- a 50 GiB `pd-balanced` data disk and a fixed IP that both outlive the VM: JSON Keys
  `10.20.0.5:5432`, Authentication `10.20.0.4:5433`, GenAI on port `5434`;
- PostgreSQL 18 from the service's `database` image, in a container limited to 0.75 vCPU, 1536 MiB
  and 50 connections, supervised by systemd.

Each database has two login roles:

- `<database>` owns the database and is the cluster's superuser. It has no password and logs in
  only through the host's local socket;
- `<database>_app` owns schema `public` and holds no superuser, role or database rights. The
  services, their migrations and their jobs connect as this role.

At boot, the host removes the owner's password and sets the application role's. The host then hands `<database>_app` every object in `public`
outside an extension, and GenAI's pg_cron jobs. Objects from an earlier superuser migration change
owner this way.

JSON Keys and Authentication each have their own **backup repository VM**, an `e2-micro`: JSON
Keys `10.20.0.6`, Authentication `10.20.0.7`. GenAI enrolls in native backups later. Foundation's
`native_backups.<service>.repository_ip` sets each address. The service root reserves it for the VM,
and the database host trusts it.

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
age-delete live data. Restores go into a disposable project; see [Recovery](runbooks/recovery.md).

Before restarting a database host, each rollout snapshots its data disk into `europe-west1`. Each
rollout also deletes that service's snapshots older than 14 days, so a snapshot lasts at least that
long. See [Undo a rollout](runbooks/database.md#undo-a-rollout).

The management project also holds `…-backups`, the bucket of the earlier logical backups. It
receives no writes, and its locked retention keeps it until it can be retired.

## Secrets

Secret containers live in the management project. Humans add their values; OpenTofu never sees
them. Operators may add and read versions of every secret.

| Secret                                                     | Read by                                                         |
| ---------------------------------------------------------- | --------------------------------------------------------------- |
| `production-json-keys-app-master-key`                      | JSON Keys runtime, rotation job                                 |
| `production-authentication-smtp-sender-password`           | Authentication API                                              |
| `production-authentication-waitlist-secret`                | Authentication API, when the waitlist is on                     |
| `production-authentication-super-admin-password`           | The initializer identity                                        |
| `production-genai-openai-api-key`                          | GenAI runtime and sweep                                         |
| `production-<service>-app-password`                        | Database host, database workloads, Authentication's initializer |
| `production-<service>-pgbackrest-{ca,database,repository}` | Database host and repository VM (TLS)                           |
| `production-downtime-discord-webhook`                      | `downtime-announcer`, when it posts a planned downtime step     |
| `production-github-dispatch-{a-novel,a-novel-kit}`         | `github-dispatcher`, when it dispatches that org's workflows    |

Workloads pin numeric versions in `terraform.tfvars`, never `latest`.

## Identities

| Account                                                                                                      | Purpose                                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `infra-plan`, `infra-foundation` (management)                                                                | CI: read-only plans and checks, and deployments.                                                                                                                               |
| `infra-downtime` (management)                                                                                | CI: starts and cancels the planned downtime announcements.                                                                                                                     |
| `infra-health` (management)                                                                                  | CI: the scheduled health check, which calls Authentication's REST API.                                                                                                         |
| `agora-json-keys-private`, `agora-authentication-private`, `agora-authentication-api`, `agora-genai-private` | Cloud Run runtimes, one per service and zone: the gRPC servers, Authentication's migrations and REST API.                                                                      |
| `agora-<service>-<role>`: `migrations`, `rotatekeys`, `sweep`, `smoke`                                       | JSON Keys' and GenAI's other workloads, each with its own account, which reads only the secrets that workload mounts. The smoke identities may only invoke their gRPC service. |
| `agora-auth-initializer`                                                                                     | Reserved for the one-time administrator initializer, which no job runs yet.                                                                                                    |
| `agora-json-keys-database`, `agora-auth-database`, `agora-genai-database`                                    | Database hosts.                                                                                                                                                                |
| `agora-pgbr-<service>`                                                                                       | Backup repository VMs.                                                                                                                                                         |
| `pgbr-<service>-recovery` (management)                                                                       | Recovery drill hosts: read and restore backups, never delete. Disabled outside drills.                                                                                         |
| `agora-scheduler-invoker`                                                                                    | Runs the rotation job, and only jobs tagged `scheduled`; calls GenAI's sweep.                                                                                                  |
| `studio-visual-ci`, `studio-visual-maintenance` (management)                                                 | `a-novel/platform-studio` CI: visual-test evidence in Google Drive, no Cloud Storage access.                                                                                   |
| `downtime-announcer` (management)                                                                            | Runs the planned downtime announcements; reads only the Discord webhook.                                                                                                       |
| `github-dispatcher`, `github-dispatch-clock` (management)                                                    | The timed workflows' clock: starts the dispatcher, which reads only the dispatch tokens.                                                                                       |

Data Access audit logs are on in the management project for IAM, Secret Manager, Cloud Storage and
token exchange.

## State

All state lives in `a-novel-management-prod-232403541574-tofu-state`, one object per root; see
[State](runbooks/state.md).

## Monitoring

- **Email channels.** Foundation has an operations channel and a cost channel. Each service runtime
  adds its own operations channel, and a service's backup alerts go to its private runtime's channel.
- **Alerts** cover Authentication's 5xx rate, GenAI's sweep failures, failed jobs and key rotation,
  database capacity, backups, and the [monthly budget](costs.md). [Alerts](runbooks/alerts.md) gives
  each threshold and what to do.
- **Health checks.** `drift.yaml` calls Authentication's `/v2/healthcheck` every three hours. Each
  deploy calls it once after applying the service roots, even when one of them failed.
- **Logs** are kept 30 days. Successful health-check requests to Authentication are not logged.
- **Traces and logs** leave the services over OTLP to Google's Telemetry API.
