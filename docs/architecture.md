# Architecture

This document is about what runs where in production, on Google Cloud. The cluster, its network and
image caches, and the management Workflows run in Paris, `europe-west9`. The Cloud Run platform it
replaces still runs in `europe-west1`, with its database hosts in zone `europe-west1-d`, until it
retires (a-novel/.github#529).

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
| `a-novel-public-prod`     | public     | Platforms: Studio, with no VPC attachment or database access.                       |

## Network

- **VPC** `agora-production` has two subnets, no load balancer and no external IP on any VM:
  - `10.20.0.0/24` holds the VMs and the workloads that stay inside Google;
  - `10.20.1.0/24`, the egress subnet, holds the Direct VPC egress of the egress allowlist's
    workloads.
- **Internet egress** leaves through Cloud NAT, which serves the egress subnet alone, from one
  reserved address, `agora-production-nat`. Foundation's `nat_address` output gives it. A VPC-wide
  default route serves NAT, and NAT logs only its errors. OpenAI's project and the Workspace SMTP
  relay admit that address alone, so a new address joins both before it replaces the old one.
- **The cluster's network,** `a-novel-production`, is built for the GKE cluster
  (a-novel/.github#522) and replaces `agora-production` at the cutover:
  - its subnet `10.30.0.0/24` holds the nodes, with the secondary ranges `pods`, `10.30.16.0/20`,
    and `services`, `10.30.4.0/22`;
  - Cloud NAT serves the whole subnet from `a-novel-production-nat`, foundation's
    `cluster_nat_address`, which OpenAI and the SMTP relay admit beside `agora-production-nat`;
  - its firewall denies all egress but the cluster's own ranges, the restricted VIP and the egress
    allowlist's destinations. The firewall sees only the nodes, so `a-novel-egress-allowlist` opens
    those destinations to every node, and each workload's network policy narrows them;
  - the peering `a-novel-database-imports` joins it to `agora-production` for the database
    imports. Apart from them, neither network admits the other: each database host admits the pod
    range on its own port, and only the database pods' network policy reaches it.
- **Google APIs** are reached through the restricted VIP ranges `199.36.153.4/30` and
  `34.126.0.0/18`. Private DNS zones resolve `googleapis.com`, `gcr.io`, `pkg.dev` and `run.app` to
  them, on both networks. GKE pulls its system images from `gcr.io`.
- **Egress allowlist.** A network firewall policy, `agora-egress-allowlist`, runs before the firewall
  rules. It lets named identities reach named destinations, and nothing else:

  | Destination                                        | Identities                                                                                                                                                       |
  | -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
  | `api.openai.com:443`                               | `agora-genai-private`, `agora-genai-sweep`                                                                                                                       |
  | Google's service ranges on 587, for the SMTP relay | `agora-authentication-api`, `agora-authentication-maintain`                                                                                                      |
  | Sentry's ingest host on 443, `sentry_ingest_host`  | `agora-authentication-api`, `agora-authentication-maintain`, `agora-json-keys-private`, `agora-json-keys-rotatekeys`, `agora-genai-private`, `agora-genai-sweep` |
  | `raw.githubusercontent.com:443`                    | None: only the cluster's nodes, for Studio's planned downtime document                                                                                           |
  | `otlp-gateway-prod-eu-west-2.grafana.net:443`      | None: only the cluster's nodes, for Alloy's telemetry                                                                                                            |

  The firewall resolves a host name through the VPC's Cloud DNS and matches the addresses it
  returns, which works only when every client gets the same answer. `api.openai.com` gives everyone
  the same two Cloudflare addresses, Sentry's ingest host, foundation's `sentry_ingest_host`, one
  Google Cloud anycast address, and Grafana's OTLP gateway one fixed address.
  `smtp-relay.gmail.com` answers each client location with another frontend, so SMTP matches the
  `google-services` address group instead: every range Google announces, minus those its Cloud
  customers rent. `refresh-google-ranges.yaml` proposes Google's latest list daily, and its pull
  request merges alone when it holds exactly what Google publishes.

  Other traffic falls through to the firewall rules. Direct VPC egress logs no firewall verdict, so
  a refused connection shows only as the caller's own error.

- **DNS allowlist.** A Cloud DNS response policy, `a-novel-dns-allowlist`, on both networks,
  resolves only the private zones, Compute Engine's internal names and the egress allowlist's hosts. Every other name answers
  with a CNAME to `blocked.internal.` and no address, so the lookup fails at once and no outside
  name server receives it. A host added to the egress allowlist joins the DNS allowlist in the same
  entry.

- **DNS query logs.** The network logs every lookup to Cloud Logging as a `dns_query` entry, with
  its name and answer. A VM's entry also carries its source address. A Cloud Run entry carries none.

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
  and JSON Keys' smoke identity may invoke it. Its egress and the rotation job's go through the VPC
  from the egress subnet: Sentry leaves through Cloud NAT, and the database and the Google APIs stay
  inside. The migrations stay on the VMs' subnet.
- **Authentication REST** has public ingress and IAM authentication, under the custom audience
  `agora-authentication-rest`. Only the platform and the health checks may invoke it, so it can
  trust the visitor IP the platform sends in `X-Client-IP`. Its egress, the maintenance job's and the
  refresh token purge's go through the VPC from the egress subnet: SMTP and Sentry leave through
  Cloud NAT, and JSON Keys stays on the restricted VIP.
- **Studio** serves visitors on its Cloud Run URL in the public project, with public ingress and
  no IAM, since visitors carry no identity. It calls Authentication's public URL with its own ID
  token, and its traces leave for Sentry directly, since the project has no VPC.
- **GenAI gRPC and sweep** have internal ingress and IAM authentication. GenAI's smoke identity
  invokes the gRPC service. Only the scheduler identity invokes the sweep. Their egress goes
  through the VPC from the egress subnet: OpenAI's API and Sentry leave through Cloud NAT.
- **Invocation tags** (`agora-invocation`: `internal`, `maintenance`, `release`, `scheduled`) gate
  who may invoke each Cloud Run service or job. Only the named maintenance operators run the
  `maintenance` job, and only they may pass it arguments.
- **Organization policies** on `a-novel-production-prod` allow only internal ingress
  (`run.allowedIngress`) and require the invoker IAM check (`run.managed.requireInvokerIam`).
  Cloud Run refuses a deploy there that breaks either. Organization admins set both by hand, and no
  CI identity holds an organization role that could lift them. Public APIs run in
  `a-novel-public-api-prod`. Both projects also keep Cloud Run's egress in the VPC
  (`run.allowedVPCEgress`).
- **A VPC Service Controls perimeter**, `a_novel_production`, holds the private and public-api
  projects. Their VPC reaches only the APIs it restricts, every API the two projects enable, and
  those APIs reach only resources inside it. CI's identities and the operators enter from anywhere.
  Any identity inside may call Secret Manager and Cloud Storage in management, for the secrets and
  the backups. Artifact Registry's VPC Service Controls setting is `ALLOW` in `europe-west9`, so the
  cluster's pull-through caches can fetch from their public registries. The perimeter enforces its
  rules and logs every call it refuses. Organization admins create its access policy and grant
  on it by hand.
- **An organization deny policy** keeps `infra-plan` from reading logs and traces, which its Viewer
  role would otherwise cover. Pull requests can mint that identity. Organization admins set the
  policy by hand, from [the setup runbook](runbooks/setup.md#organization-guardrails).

## Cluster

`a-novel-production` is the GKE Standard cluster that replaces Cloud Run at the cutover
(a-novel/.github#522). Its workloads serve no one until then. The `cluster` root manages its
Kubernetes resources, reaching the control plane through the DNS endpoint as the CI identities.

- **Zonal,** so the billing account's free tier covers its management fee. The control plane runs in
  `europe-west9-a`, and the nodes in `a` and `b`.
- **Nodes:** the `general` pool, three `e2-highmem-4` nodes that autoscale to four, with private
  addresses only. They run as `a-novel-cluster-nodes`, and upgrades add a node before draining one.
- **Access:** outside the network, the control plane answers only through its DNS endpoint, which
  IAM and the perimeter guard. Nodes use its internal endpoint. Operators read each service's
  namespace through Kubernetes' `view` role, which never reads Secrets. The named maintenance
  operators create Jobs in `authentication`, which an admission policy holds to the `maintenance`
  template but for their arguments.
- **Isolation:** Dataplane V2 enforces network policies, FQDN ones included. Workload Identity gives
  each pod its own identity, never the node's. Every namespace the cluster root manages enforces
  Pod Security's `restricted` level and two admission policies: images only from our Artifact
  Registry, pinned by digest, and no `LoadBalancer` Service. The services' namespaces deny all
  traffic but DNS until a workload's own policy opens a path. FQDN network policies give each
  workload its own internet hosts, matched on its own lookups: OpenAI for GenAI, the mail relay
  for Authentication, GitHub's raw host for Studio, Grafana's gateway for Alloy. After each apply,
  the deploy sends dry-run requests that admission must refuse, and one compliant pod it must admit.
- **Budgets:** each service's namespace has its own ResourceQuota, the cluster root's
  `service_budgets`: the CPU and memory its pods may request in all, and how many run. Its
  autoscalers grow inside it, so one service cannot take the room another needs; raising one is a
  deliberate change. A default request covers containers that set none.
- **Images:** the add-ons pull Docker Hub, ghcr.io, quay.io and registry.k8s.io images through the
  Artifact Registry pull-through caches `a-novel-docker-io`, `a-novel-ghcr-io`, `a-novel-quay-io`
  and `a-novel-registry-k8s-io`, which only the nodes read. The cluster root pins each image by
  digest.
- **Add-ons:** the cluster root installs cert-manager, the CloudNativePG operator, its Barman Cloud
  plugin, External Secrets and Grafana's `k8s-monitoring` chart with Helm, each in its own
  namespace. Renovate moves each chart with its images after a week, and merges a minor or patch
  update on its own.
- **Telemetry:** one Alloy pod in the `alloy` namespace sends every signal to the Grafana Cloud
  stack's OTLP gateway. The workloads export their traces and logs to its OTLP/HTTP receiver. It
  gives each server and root span an outcome, `a_novel.outcome`, then derives span metrics from
  them, with a native histogram of their duration. CloudNativePG also exports each database's own
  numbers, such as accounts, tokens consumed or signing keys' runway, from the cluster root's
  `queries/<database>.yaml`. It runs them as `cnpg_metrics_exporter`, which reads only the columns
  `queries/<database>.sql` grants it: a Job runs those grants as the tables' owner after each run of
  the migrations. Alloy scrapes the kubelets, cAdvisor, kube-state-metrics and the databases every
  60 seconds, and sends the Kubernetes events, all in the cluster root's namespaces. It reads its push token from `production-alloy-push-token`, and
  no Secret of the cluster. The Alloy Operator, which the chart runs, manages that namespace alone.
- **Edge:** Studio answers on `studio.storyverse.fr` through the Gateway `studio`, on Google's
  global load balancer, which redirects plain HTTP to HTTPS. Foundation holds its `studio` address,
  a TLS 1.2 policy, and a Certificate Manager certificate the domain's DNS authorizes before any
  traffic moves. Only the load balancer's ranges reach Studio's pods.
- **Scaling:** an autoscaler absorbs bursts only. It adds or removes one pod a minute at most, and
  removes one only after five minutes below its targets. A workload's maximum moves by pull request,
  which the `Workload autoscaler at its maximum` alert prompts. GenAI's server scales on CPU and on
  its calls in flight, at 60% of `GRPC_MAX_CONCURRENT_CALLS` per pod: GKE reads that gauge from
  each pod's metrics port through an `AutoscalingMetric`. Its maximum of three pods times that cap
  bounds the calls it runs at once, and so its OpenAI spend.
- **Jobs:** each new migrations image runs once as a Job before its server rolls. CronJobs run
  JSON Keys' key rotation hourly at :10 and Authentication's refresh token purge daily at 03:40
  UTC, one run at a time, never retried. The suspended `maintenance` CronJob holds the template of
  Authentication's maintenance Jobs, which the [setup runbook](runbooks/setup.md) runs.
- **Health checks:** the shared health check, `modules/smoke-check/smoke.sh`, calls JSON Keys' and
  GenAI's `Status` RPC and Authentication's `/v2/healthcheck`, as the namespace's `smoke` identity
  with a service token for the service's audience. A `smoke-<hash>` Job runs it on each new image,
  script or setting, and the deploy waits on it. Each namespace's `health` CronJob runs it every
  five minutes, so a failing service shows as failed Jobs. Both skip a planned downtime.
- **OpenAI call:** the `provider-check-<revision>` Job submits one small generation to GenAI, as
  its `smoke` identity, and polls it until it settles. It runs once for each new value of the
  cluster root's `genai_provider_check`, the deploy waits on it, and it fails unless the generation
  succeeds. It skips a planned downtime.
- **Upkeep:** the `REGULAR` release channel upgrades it during weekly windows, Tuesday to Thursday
  from 01:00 to 07:00 UTC. Google collects only system logs and metrics, since Grafana takes every
  signal.

## Services

| Service        | Cloud Run                                                                                                                                                                                                                         | Jobs                                                                                                                                                                |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| JSON Keys      | `agora-json-keys-grpc`: 1–2 instances, private ingress, CPU always allocated                                                                                                                                                      | `migrations` (runs at deploy), `rotatekeys` (Scheduler hourly at :10; the job keeps 24 h between rotations), `smoke` (probes each new image)                        |
| Authentication | `agora-authentication-rest`: 1 instance, which holds the in-memory rate limits; public ingress, CPU always allocated for detached mail                                                                                            | `migrations` (runs at deploy, in the private project), `refresh-token-purge` (Scheduler daily at 03:40; deletes the sign-out revocations of expired refresh tokens) |
| GenAI          | `agora-genai-grpc`: 0–4 instances, private ingress, CPU always allocated; `agora-genai-sweep`: 0–1 instance, private ingress, CPU only during requests, which Scheduler calls every minute to check the generations nobody polled | `migrations` (runs at deploy), `smoke` (probes each new image)                                                                                                      |

**A service a consumer waits on keeps CPU always allocated.** That covers a public API and every
service it calls, such as JSON Keys and GenAI's gRPC server. Sentry and OpenTelemetry send their
data from the background after a response, and request-based billing withdraws the CPU once an
instance answers. A service no consumer waits on, such as the sweep, is billed per request and sends
its telemetry before each answer completes, through golib's `httpf.SendTelemetry`.

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
from `…-tooling`.

## Databases and backups

Each service has its own **database host**, sized in foundation's `database_capacity`. GenAI's rows
hold payloads and responses of up to 24 MiB, so its host is larger.

On the cluster, each service's namespace holds a CloudNativePG database named `database`: a
primary and a replica on separate nodes, with today's host sizes, switching over on updates. It
starts as an import of the service's host, when it has one: CloudNativePG dumps the host's database
as the role that owns its tables and restores it as `app`, leaving pg_cron's jobs out. A new
service's database starts empty. Each lineage archives under
the cluster's `backup_server_name`. A new name recreates the database four minutes after deleting
the old one, so the operator's objects for the two never overlap, imports it again, rolls the
service's pods and takes a base backup at once; bootstrap's `retired_barman_lineages` then expires
the former lineage after 15 days. The rehearsal imports a copy of production this way, and the
cutover imports it again (a-novel/infra#1202). CloudNativePG generates its credentials, in the
`database-app` Secret, for the database and owner `app`. It serves TLS for `database-rw.<service>.svc`
from cert-manager's ten-year `databases` CA, which keeps its key when renewed. The same CA issues
its replica's `streaming_replica` certificate, named `streaming-replica.<service>`, which only that
database maps to the role. The service's pods
connect by that name and trust that CA beside the system roots. Its image catalog takes the service's
release image from foundation, and GenAI preloads `pg_cron`. The deploy waits until both instances
serve and WAL reaches Barman; a daily base backup runs from the replica. Each database backs up to
its own Barman bucket in management, `<prefix>-barman-<service>`. Each bucket has the pgBackRest
buckets' protections, and only that database's Kubernetes service account, `database` in the
service's namespace, writes it through Workload Identity. The nodes pull each service's PostgreSQL
image from its private repository, as its host does. While a
[recovery drill](runbooks/recovery.md#cluster-databases) runs, each database it restores reads its
own service's bucket through the `barmanReader` role, and writes none.

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
`e2-micro`: JSON Keys `10.20.0.6`, Authentication `10.20.0.7`. Foundation reserves each address,
which Google picks, for every service in `pgbackrest_repository_services`. The service root pins its
VM to it, and the database host trusts it. GenAI has an address but no native backups yet.

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

| Secret                                                     | Read by                                                                          |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `production-json-keys-app-master-key`                      | JSON Keys runtime, rotation job                                                  |
| `production-authentication-waitlist-secret`                | Authentication API, when the waitlist is on                                      |
| `production-genai-openai-api-key`                          | GenAI runtime and sweep                                                          |
| `production-<service>-app-password`                        | Database host and database workloads                                             |
| `production-<service>-pgbackrest-{ca,database,repository}` | Database host and repository VM (TLS)                                            |
| `production-downtime-discord-webhook`                      | `downtime-announcer`, when it posts a planned downtime step                      |
| `production-github-dispatch-{a-novel,a-novel-kit}`         | `github-dispatcher`, when it dispatches that org's workflows                     |
| `production-github-plan-key-<org>`                         | `infra-plan`, when it plans the GitHub root                                      |
| `production-github-deploy-key-<org>`                       | `infra-github` and `infra-drift`, when they apply or drift-check the GitHub root |
| `production-github-governance-<org>-<name>`                | `infra-github`, when it copies them into the governance environments             |

## Identities

| Account                                                                                                      | Purpose                                                                                                                                                                                                                                                                 |
| ------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `infra-plan`, `infra-foundation` (management)                                                                | CI: read-only plans and checks, and deployments. In the cluster, `infra-plan` reads every object but Secrets, and `infra-foundation` administers it.                                                                                                                    |
| `infra-downtime` (management)                                                                                | CI: starts and cancels the planned downtime announcements.                                                                                                                                                                                                              |
| `infra-health` (management)                                                                                  | CI: the scheduled health check, which calls Authentication's REST API and Studio.                                                                                                                                                                                       |
| `infra-github` (management)                                                                                  | CI: the GitHub root's deploys and sweep, from the `github` environment. It reads the Deploy App keys, the governance secrets and its own state, and holds no Google Cloud role.                                                                                         |
| `infra-drift` (management)                                                                                   | CI: the GitHub root's drift check, which reads the Deploy App keys.                                                                                                                                                                                                     |
| `infra-grafana` (management)                                                                                 | CI: the Grafana root's deploys, from the `grafana` environment. It reads the Grafana write tokens and its own state, and holds no Google Cloud role.                                                                                                                    |
| `agora-json-keys-private`, `agora-authentication-private`, `agora-authentication-api`, `agora-genai-private` | Cloud Run runtimes, one per service and zone: the gRPC servers, Authentication's migrations and REST API.                                                                                                                                                               |
| `agora-<service>-<role>`: `migrations`, `rotatekeys`, `sweep`, `smoke`, `maintain`                           | All the services' other workloads, each with its own account, which reads only the secrets that this workload mounts. The smoke identities may only invoke their gRPC service. Authentication's refresh token purge runs as `maintain`, with the same image and secret. |
| `agora-json-keys-database`, `agora-auth-database`, `agora-genai-database`                                    | Database hosts.                                                                                                                                                                                                                                                         |
| `agora-pgbr-<service>`                                                                                       | Backup repository VMs.                                                                                                                                                                                                                                                  |
| `a-novel-cluster-nodes`                                                                                      | The cluster's nodes: GKE's default node role alone, to write their logs and metrics and pull images. Workloads use their own identities.                                                                                                                                |
| `pgbr-<service>-recovery` (management)                                                                       | Recovery drill hosts: read and restore backups, never delete. Disabled outside drills.                                                                                                                                                                                  |
| `agora-scheduler-invoker`                                                                                    | Runs the rotation and refresh token purge jobs, and only jobs tagged `scheduled`; calls GenAI's sweep.                                                                                                                                                                  |
| `<slug>-visual-ci`, `<slug>-visual-maintenance` (management)                                                 | The CI of studio, template and a-novel-kit/uikit: visual-test evidence in Google Drive, no Cloud Storage access.                                                                                                                                                        |
| `downtime-announcer` (management)                                                                            | Runs the planned downtime announcements; reads only the Discord webhook.                                                                                                                                                                                                |
| `github-dispatcher`, `github-dispatch-clock` (management)                                                    | The timed workflows' clock: starts the dispatcher, which reads only the dispatch tokens.                                                                                                                                                                                |

Data Access audit logs are on in the management project for IAM, Secret Manager, Cloud Storage and
token exchange.

## State

All state lives in `a-novel-management-prod-232403541574-tofu-state`, one object per root, as
[State](runbooks/state.md) details.

## Repository config

The GitHub root, `environments/production/github`, holds every repository of both organizations
and the config their code does not: settings, team access, labels, Pages, the Dependabot toggles,
rulesets, environments and scoped secret access. Each repository takes its class's settings from
`main.tf`, then its own overrides from `terraform.tfvars`, field by field. A new repository starts
from its class's template, `service-template` or `platform-template`, or empty. Removing one
archives it.

- **The code stays the source of truth.** Discovery reads each repository's default branch: the
  required checks are the always-required set plus `main.yaml`'s jobs, minus reporting and
  master-only ones; the secrets and environments come from every workflow; and the root
  `package.json`'s major names the retired release lines. Each repository owns its workflows,
  Renovate's updates included.
- **A repository waits until it is ready.** Until its default branch holds `main.yaml`, it gets
  settings, team access and labels only. Readiness never depends on another workflow's name: each
  repository names its workflows as it likes.
- **Secret sync copies the governance secrets.** After each apply, the deploy job and the sweep
  copy each repository's privileged keys from Secret Manager, at the versions `terraform.tfvars`
  pins, into its `governance` environment, as `.github/scripts/secret-sync.mjs` does.
- **Asserts cover what the provider cannot manage.** After each apply, the deploy job and the
  sweep keep code scanning default setup and Code Quality off, fork pull request approval at
  `all_external_contributors` and pull request creation limited to collaborators, on every
  repository, as `.github/scripts/repository-asserts.mjs` does. The drift check reads the same
  settings and warns when one differs. Each assert names the issue that replaces it with a
  provider resource.
- **Prune removes what the root does not produce.** A ruleset or deployment pattern made by hand
  fails `plan-github` on the next pull request that changes the root, until a maintainer adds
  `allow-resource-deletion`, and the deploy of that pull request deletes it, as
  `.github/scripts/prune.mjs` does. It reads patterns only in the environments the root manages,
  never deletes an environment, and the sweep never prunes. Secret sync deletes the governance
  secrets no workflow names.
- **Only the guarded environments are managed:** `release`, with its reviewers, `governance` and
  `sourcemaps`, each open on the refs a ruleset guards. GitHub creates the others, such as
  `github-pages` and `copilot`.

- **Each organization has two GitHub Apps.** Pull requests plan with the read-only Plan App, and
  deploys apply with the Deploy App, as [GitHub root keys](runbooks/secrets.md#github-root-keys)
  describes.
- **Pull requests plan without refreshing.** GitHub hides bypass lists, merge settings and security
  settings from the Plan App, so a pull request plans against what the last deploy applied. Deploys
  refresh with the Deploy App, which sees them.
- **A pull request plans the root only when its merge applies it:** when it changes what the root
  depends on, as `.github/scripts/root-changes.sh` lists for the deploy, or carries
  `allow-resource-deletion`. Even unrefreshed, a plan reads every repository's workflows and pages
  through each file's commit history, from the Plan App's hourly budget that all pull requests
  share.
- **Team access is authoritative; labels are not.** A team or person granted by hand loses access at
  the next apply. Only the managed labels are enforced: the Epic, gate and Dependabot labels stay.
- **It applies from its own environment and identity,** `github` and `infra-github`, apart from
  Google Cloud's production: in `deploy.yaml`'s own `github` job when it changes, which no release
  waits on, and from `sweep.yaml`.
- **The sweep follows the code.** The dispatch clock starts `sweep.yaml` every 10 minutes. When a
  repository's workflows or root `package.json` changed since the last successful sweep, it applies
  the root, and refuses any deletion, which waits for a pull request with `allow-resource-deletion`.
  The clock starts the daily drift check too, which plans this root as `infra-drift`.

## Monitoring

- **Grafana** receives every signal from the cluster, through Alloy. The Grafana root,
  `environments/production/grafana`, holds its alert rules and dashboards, and its notification
  policy posts every alert to the Discord contact point, which core creates by hand so its webhook
  never reaches state. [Grafana alerts](runbooks/alerts.md#grafana-alerts) gives each rule. The root
  applies only when it changes, in `deploy.yaml`'s own `grafana` job, which no release waits on.
  That job runs in its own environment and identity, `grafana` and `infra-grafana`, apart from
  Google Cloud's production.
- **Alerts** email an operations channel: foundation's, or the service runtime's own. They cover
  Authentication's 5xx rate, GenAI's sweep failures, failed jobs and key rotation, database
  capacity, backups, and the [monthly budget](costs.md). [Alerts](runbooks/alerts.md) gives each
  threshold and what to do.
- **Health checks** call Authentication's `/v2/healthcheck` and Studio's `/healthcheck` after each
  deploy and from `drift.yaml`, as [Authentication health](runbooks/alerts.md#authentication-health)
  details. On the cluster, each service's `health` CronJob checks it every five minutes, and
  kube-state-metrics reports its failed Jobs.
- **Logs** are kept 30 days. Successful health-check requests to Authentication and successful
  database health probes are not logged.
- **Traces and logs** leave the services over OTLP/HTTP to each service's Sentry project, on the
  ingest host error events use. The perimeter still restricts the Telemetry and Cloud Trace APIs,
  so no workload can export to another project's.
