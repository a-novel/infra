# Architecture

What runs where. Region `europe-west1`, database zone `europe-west1-d`.

## Projects

| Project                   | Zone       | Holds                                                                                 |
| ------------------------- | ---------- | ------------------------------------------------------------------------------------- |
| `a-novel-management-prod` | management | State bucket, backup buckets, secrets, CI identities. Survives a workload rebuild.    |
| `a-novel-production-prod` | private    | Shared VPC host, database and backup VMs, JSON Keys, all jobs, the rotation schedule. |
| `a-novel-public-api-prod` | public-api | Authentication REST API, attached to the private VPC.                                 |
| `a-novel-public-prod`     | public     | Reserved for platforms; no VPC attachment, no database access.                        |

## Network

- **VPC** `agora-production`, with one subnet `10.20.0.0/24`. There are no NAT gateways, routers,
  load balancers or external IPs.
- **Google APIs** are reached through the restricted VIP `199.36.153.4/30`, using private DNS zones
  for `googleapis.com`, `pkg.dev` and `run.app`.
- **Firewall.** A VPC-wide deny-all egress rule (priority 1200) sits below explicit allows:
  - PostgreSQL from the subnet only;
  - pgBackRest TLS on 8432, database host to repository host only;
  - SSH only from Identity-Aware Proxy, `35.235.240.0/20`.
- **JSON Keys gRPC** has internal ingress and IAM authentication. Only Authentication and the smoke
  job may invoke it.
- **Authentication REST** has public ingress. Its egress reaches private ranges through the VPC,
  and SMTP through Google's managed egress.

## Services

| Service        | Cloud Run                                                                   | Jobs                                                                                                                                         |
| -------------- | --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| JSON Keys      | `agora-json-keys-grpc`: 1–3 instances, private                              | `migrations` (runs at deploy), `rotatekeys` (Scheduler hourly at :10; the job keeps 24 h between rotations), `smoke` (probes each new image) |
| Authentication | `agora-authentication-rest`: 1–3 instances, always-on CPU for detached mail | `migrations` (runs at deploy, in the private project)                                                                                        |

Images come from `ghcr.io/a-novel/*`. Each is pinned as `tag@digest` in the service root's
`terraform.tfvars`, verified against its GitHub attestation, and copied to the service's own Artifact
Registry repository before apply.

## Databases and backups

Each service has its own **database host**:

- a Container-Optimized OS VM in a size-1 instance group;
- a stateful 50 GiB data disk and a fixed IP: JSON Keys `10.20.0.5:5432`, Authentication
  `10.20.0.4:5433`;
- PostgreSQL 18 from the service's `database` image, supervised by systemd.

Each service also has its own **backup repository host**, an `e2-micro`: JSON Keys `10.20.0.6`,
Authentication `10.20.0.7`.

- The database host archives WAL and runs backups through pgBackRest over mutual TLS to the
  repository host.
- The repository host writes to the management bucket `…-pgbr-<service>`.

| Schedule (UTC)        | Job                                |
| --------------------- | ---------------------------------- |
| Sunday 02:00          | full backup                        |
| Monday–Saturday 02:00 | differential backup                |
| hourly at :30         | archive check and TLS expiry check |

Retention keeps full chains for 14 days. pgBackRest owns expiry; the buckets never age-delete live
data. Restores go into a disposable project; see [recovery](runbooks/recovery.md).

## Secrets

Secret containers live in the management project; values are added by humans, never by OpenTofu.

| Secret                                                     | Read by                                     |
| ---------------------------------------------------------- | ------------------------------------------- |
| `production-json-keys-postgres-password`                   | JSON Keys runtime, database host            |
| `production-json-keys-app-master-key`                      | JSON Keys runtime                           |
| `production-authentication-postgres-password`              | Authentication runtimes, database host      |
| `production-authentication-smtp-sender-password`           | Authentication API                          |
| `production-authentication-waitlist-secret`                | Authentication API, when the waitlist is on |
| `production-authentication-super-admin-password`           | One-time administrator initializer          |
| `production-<service>-pgbackrest-{ca,database,repository}` | Database host and repository host (TLS)     |

Workloads pin numeric versions in `terraform.tfvars`, never `latest`.

## Identities

| Account                                               | Purpose                                                  |
| ----------------------------------------------------- | -------------------------------------------------------- |
| `infra-plan`, `infra-foundation` (management)         | CI: read-only plans, and deployments.                    |
| `agora-<service>-private`, `agora-authentication-api` | Cloud Run runtimes, one per service and zone.            |
| `agora-json-keys-database`, `agora-auth-database`     | Database hosts.                                          |
| `agora-pgbr-<service>`                                | Backup repository hosts.                                 |
| `pgbr-<service>-recovery` (management)                | Disaster-recovery hosts: read-only access to backups.    |
| `agora-scheduler-invoker`                             | Runs the rotation job, and only jobs tagged `scheduled`. |

## State

All state lives in `a-novel-management-prod-232403541574-tofu-state`. The bucket keeps 90 days of
versions and 7 days of soft-deleted objects.

| Prefix                          | Root                  |
| ------------------------------- | --------------------- |
| `bootstrap/`, `foundation/`     | bootstrap, foundation |
| `json-keys/`, `authentication/` | service roots         |
| `recovery/<project>/`           | one recovery drill    |

## Observability

- **Email channels.** Operations alerts and cost alerts each go to their own channel.
- **Alerts:**
  - Authentication REST 5xx above 10%;
  - failed jobs, or no successful key rotation;
  - database CPU, memory and disk;
  - backup failures and missed backups, per service;
  - the monthly budget at 50, 75, 90 and 100% of 60 units, current and forecast.
- **Health checks.** `drift.yaml` calls `/v2/healthcheck` every three hours, and every deploy calls
  it once. The 3-hour cadence keeps Authentication from staying billed between requests.
- **Logs** are kept 30 days; successful health-check requests are not logged.
- **Traces and logs** leave the services over OTLP to Google's Telemetry API.

## Platform visual tests

Bootstrap also federates `a-novel/platform-studio` CI with two Google identities. They store
visual-test evidence in Google Drive and have no Cloud Storage access.
