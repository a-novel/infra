# Architecture

This document describes what runs where in production, on Google Cloud: projects, network,
services, databases and backups, secrets, identities, state and monitoring. Region `europe-west1`,
database zone `europe-west1-d`.

## Projects

Production is split into four projects, one per trust zone, so each one holds only the access its
contents need.

| Project                   | Zone       | Holds                                                                                 |
| ------------------------- | ---------- | ------------------------------------------------------------------------------------- |
| `a-novel-management-prod` | management | State bucket, backup buckets, secrets, CI identities. Survives a workload rebuild.    |
| `a-novel-production-prod` | private    | Shared VPC host, database and backup VMs, JSON Keys, all jobs, the rotation schedule. |
| `a-novel-public-api-prod` | public-api | Authentication REST API, attached to the private VPC.                                 |
| `a-novel-public-prod`     | public     | Reserved for platforms; no VPC attachment, no database access.                        |

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
  and JSON Keys' own private identity, shared by its gRPC service and its jobs, may invoke it.
- **Authentication REST** has public ingress and IAM authentication, under the custom audience
  `agora-authentication-rest`. Only the platform and the deploy health check may invoke it, so it
  trusts the visitor IP the platform sends in `X-Client-IP`. Its egress reaches private ranges
  through the VPC, and SMTP through Google's managed egress.
- **Invocation tags** (`agora-invocation`: `initializer`, `internal`, `release`, `scheduled`) gate
  who may invoke each Cloud Run service or job.

## Services

| Service        | Cloud Run                                                                                                                              | Jobs                                                                                                                                         |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| JSON Keys      | `agora-json-keys-grpc`: 1–2 instances, private ingress, CPU only during requests                                                       | `migrations` (runs at deploy), `rotatekeys` (Scheduler hourly at :10; the job keeps 24 h between rotations), `smoke` (probes each new image) |
| Authentication | `agora-authentication-rest`: 1 instance, which holds the in-memory rate limits; public ingress, CPU always allocated for detached mail | `migrations` (runs at deploy, in the private project)                                                                                        |

Service images come from `ghcr.io/a-novel/*`. Each is pinned as `tag@digest` in the service root's
`terraform.tfvars`, and its database image in foundation's too. Before applying, deploy verifies
each image's attestation against its service's release workflow and copies it to Artifact Registry.

Artifact Registry holds `agora-production`, for the database images, and two repositories per
service and zone, `…-production` and `…-tooling`, all with immutable tags. The tooling repositories
hold the [host tools](runbooks/host-tools.md), pinned by digest.

## Databases and backups

Each service has its own **database host**:

- a Container-Optimized OS VM, `e2-medium`, the only member of a stateful instance group. Its COS
  image is pinned, and automatic OS updates are off;
- a 50 GiB `pd-balanced` data disk and a fixed IP that both outlive the VM: JSON Keys
  `10.20.0.5:5432`, Authentication `10.20.0.4:5433`;
- PostgreSQL 18 from the service's `database` image, in a container limited to 0.75 vCPU, 1536 MiB
  and 50 connections, supervised by systemd.

Each service also has its own **backup repository VM**, an `e2-micro`: JSON Keys `10.20.0.6`,
Authentication `10.20.0.7`. Foundation's `native_backups.<service>.repository_ip` sets that address:
the service root reserves it for the VM, and the database host trusts it.

- The database host archives WAL and runs backups with pgBackRest, over mutual TLS, to its
  repository VM.
- The repository VM writes them to the management bucket `…-pgbr-<service>`. The bucket is
  versioned, refuses to delete an object younger than 7 days, and keeps deleted objects 7 more days.

| Schedule (UTC)        | Job                                |
| --------------------- | ---------------------------------- |
| Sunday 02:00          | full backup                        |
| Monday–Saturday 02:00 | differential backup                |
| hourly at :30         | archive check and TLS expiry check |

Each timer adds up to five minutes of random delay. pgBackRest keeps full backups, and the WAL and
differentials that depend on them, for 14 days, and owns their expiry: the buckets never age-delete
live data. Restores go into a disposable project; see [Recovery](runbooks/recovery.md).

Before restarting a database host, each rollout snapshots its data disk into `europe-west1`. Each
rollout also deletes that service's snapshots older than 14 days, so a snapshot lasts at least that
long. See [Undo a rollout](runbooks/database.md#undo-a-rollout).

The management project also holds `…-backups`, the bucket of the earlier logical backups. Nothing
writes to it any more; its locked retention keeps it until it can be retired.

## Secrets

Secret containers live in the management project. Humans add their values; OpenTofu never sees
them. Operators may add and read versions of every secret.

| Secret                                                     | Read by                                                          |
| ---------------------------------------------------------- | ---------------------------------------------------------------- |
| `production-json-keys-postgres-password`                   | JSON Keys runtime, database host                                 |
| `production-json-keys-app-master-key`                      | JSON Keys runtime                                                |
| `production-authentication-postgres-password`              | Authentication runtimes, the initializer identity, database host |
| `production-authentication-smtp-sender-password`           | Authentication API                                               |
| `production-authentication-waitlist-secret`                | Authentication API, when the waitlist is on                      |
| `production-authentication-super-admin-password`           | The initializer identity                                         |
| `production-<service>-pgbackrest-{ca,database,repository}` | Database host and repository VM (TLS)                            |
| `production-downtime-discord-webhook`                      | `downtime-announcer`, when it posts a planned downtime step      |

Workloads pin numeric versions in `terraform.tfvars`, never `latest`.

## Identities

| Account                                                                               | Purpose                                                                                      |
| ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `infra-plan`, `infra-foundation` (management)                                         | CI: read-only plans and checks, and deployments.                                             |
| `agora-json-keys-private`, `agora-authentication-private`, `agora-authentication-api` | Cloud Run runtimes, one per service and zone.                                                |
| `agora-auth-initializer`                                                              | Reserved for the one-time administrator initializer, which no job runs yet.                  |
| `agora-json-keys-database`, `agora-auth-database`                                     | Database hosts.                                                                              |
| `agora-pgbr-<service>`                                                                | Backup repository VMs.                                                                       |
| `pgbr-<service>-recovery` (management)                                                | Recovery drill hosts: read and restore backups, never delete. Disabled outside drills.       |
| `agora-scheduler-invoker`                                                             | Runs the rotation job, and only jobs tagged `scheduled`.                                     |
| `studio-visual-ci`, `studio-visual-maintenance` (management)                          | `a-novel/platform-studio` CI: visual-test evidence in Google Drive, no Cloud Storage access. |
| `downtime-announcer` (management)                                                     | Runs the planned downtime announcements; reads only the Discord webhook.                     |

Data Access audit logs are on in the management project for IAM, Secret Manager, Cloud Storage and
token exchange.

## State

All state lives in `a-novel-management-prod-232403541574-tofu-state`, one object per root; see
[State](runbooks/state.md).

## Monitoring

- **Email channels.** Foundation has an operations channel and a cost channel. Each service runtime
  adds its own operations channel, and a service's backup alerts go to its private runtime's channel.
- **Alerts** cover Authentication's 5xx rate, failed jobs and key rotation, database capacity,
  backups, and the monthly budget of 60 units of the billing account's currency, for the four
  production projects. [Alerts](runbooks/alerts.md) gives each threshold and what to do.
- **Health checks.** `drift.yaml` calls Authentication's `/v2/healthcheck` every three hours, and
  each deploy that changed a service calls it once.
- **Logs** are kept 30 days. Successful health-check requests to Authentication are not logged.
- **Traces and logs** leave the services over OTLP to Google's Telemetry API.
