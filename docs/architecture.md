# Architecture

This document is about what runs where in production, on Google Cloud. Everything runs in Paris,
`europe-west9`: the services on one GKE cluster in the workload project, and the state, secrets and
backups in the management project.

## Projects

| Project                   | Holds                                                                                      |
| ------------------------- | ------------------------------------------------------------------------------------------ |
| `a-novel-management-prod` | State bucket, backup buckets, secrets, CI identities, Cloud Workflows. Survives a rebuild. |
| `a-novel-production-prod` | The network, the cluster, its image repositories and the platforms' public edges.          |

Services keep apart inside the cluster, each in its own namespace, as [Cluster](#cluster) describes.

## Network

- **VPC** `a-novel-production` has one subnet, `10.30.0.0/24`, which holds the nodes, with the
  secondary ranges `pods`, `10.30.16.0/20`, and `services`, `10.30.4.0/22`. It starts without
  Google's default routes, and no node has an external address.
- **Internet egress** leaves through Cloud NAT from one reserved address, `a-novel-production-nat`,
  foundation's `cluster_nat_address`. NAT logs only its errors. OpenAI's project and the Workspace
  SMTP relay admit that address alone, so a new address joins both before it replaces the old one.
- **Google APIs** are reached through the restricted VIP ranges `199.36.153.4/30` and
  `34.126.0.0/18`. Private DNS zones resolve `googleapis.com`, `gcr.io` and `pkg.dev` to them. GKE
  pulls its system images from `gcr.io`.
- **Firewall.** A network-wide rule denies all egress at priority 1200. Rules at priority 800 allow
  the cluster's own node and pod ranges, and HTTPS to the Google API ranges. The egress allowlist
  runs before them.
- **Egress allowlist.** A network firewall policy, `a-novel-egress-allowlist`, lets the nodes reach
  the hosts below, and nothing else on the internet. The firewall sees only the nodes, so each
  workload's FQDN network policy narrows the list to its own hosts:

  | Destination                                                | Pods                                            |
  | ---------------------------------------------------------- | ----------------------------------------------- |
  | `api.openai.com:443`                                       | GenAI's `grpc` and `sweep`                      |
  | Google's service ranges on 587, for `smtp-relay.gmail.com` | Authentication's `rest` and `maintenance`       |
  | `raw.githubusercontent.com:443`                            | The platforms' `web`, for the downtime document |
  | `otlp-gateway-prod-eu-west-2.grafana.net:443`              | Alloy, for telemetry                            |

  The firewall resolves a host name through the VPC's Cloud DNS and matches the addresses it
  returns, which works only when every client gets the same answer. `api.openai.com` gives everyone
  the same two Cloudflare addresses, GitHub's raw host the same four, and Grafana's OTLP gateway one
  fixed address.
  `smtp-relay.gmail.com` answers each client location with another frontend, so SMTP matches the
  `google-services` address group instead: every range Google announces, minus those its Cloud
  customers rent. `refresh-google-ranges.yaml` proposes Google's latest list daily, and its pull
  request merges alone when it holds exactly what Google publishes.

  Other traffic falls through to the firewall rules, which log no verdict, so a refused connection
  shows only as the caller's own error.

- **DNS allowlist.** A Cloud DNS response policy, `a-novel-dns-allowlist`, resolves only the private
  zones, Compute Engine's internal names and the egress allowlist's hosts. Every other name answers
  with a CNAME to `blocked.internal.` and no address, so the lookup fails at once and no outside
  name server receives it. A host added to the egress allowlist joins the DNS allowlist in the same
  entry.
- **DNS query logs.** The DNS policy `a-novel-production` logs every lookup to Cloud Logging as a
  `dns_query` entry, with its name and answer.
- **A VPC Service Controls perimeter**, `a_novel_production`, holds the workload project. Its VPC
  reaches only the APIs the perimeter restricts, and those APIs reach only resources inside it. CI's
  identities and the operators enter from anywhere. Any identity inside may call Secret Manager and
  Cloud Storage in management, for the secrets and the backups. Artifact Registry's VPC Service
  Controls setting is `ALLOW` in `europe-west9`, so the pull-through caches can fetch from their
  public registries. The perimeter enforces its rules and logs every call it refuses. Organization
  admins create its access policy and grant on it by hand.
- **An organization deny policy** keeps `infra-plan` from reading logs and traces, which its Viewer
  role would otherwise cover. Pull requests can mint that identity. Organization admins set the
  policy by hand, from [the setup runbook](runbooks/setup.md#organization-guardrails).

## Cluster

`a-novel-production` is a GKE Standard cluster. The `cluster` root manages its Kubernetes
resources, reaching the control plane through the DNS endpoint as the CI identities.

- **Zonal,** so the billing account's free tier covers its management fee. The control plane runs in
  `europe-west9-a`, and the nodes in `a` and `b`.
- **Nodes:** the `general` pool, three `e2-highmem-4` nodes that autoscale to four, with private
  addresses only, as foundation's `cluster` sets. They run as `a-novel-cluster-nodes`, and upgrades
  add a node before draining one.
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
  workload its own internet hosts, matched on its own lookups. After each apply, the deploy sends
  dry-run requests that admission must refuse, and one compliant pod it must admit.
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
- **Counter store:** one Valkey pod in the `authentication` namespace, from the official chart,
  holds only the rate-limit counters, up to 64 MiB, evicting the least recently used first. It
  keeps nothing on disk. Its users each get a password External Secrets generates once into the
  `valkey-users` Secret: the limiter reaches the `httprate:*` keys alone, and the exporter reads
  statistics and no key. Only Authentication's API pods reach Valkey, and only Alloy its exporter.
- **Telemetry:** one Alloy pod in the `alloy` namespace sends every signal to the Grafana Cloud
  stack's OTLP gateway. The workloads export their traces and logs to its OTLP/HTTP receiver. It
  gives each server and root span an outcome, `a_novel.outcome`, then derives span metrics from
  them, with a native histogram of their duration. CloudNativePG also exports each database's own
  numbers, such as accounts, tokens consumed or signing keys' runway, from the cluster root's
  `queries/<database>.yaml`. It runs them as `cnpg_metrics_exporter`, which reads only the columns
  `queries/<database>.sql` grants it: a Job runs those grants as the tables' owner after each run of
  the migrations. Alloy scrapes the kubelets, cAdvisor, kube-state-metrics, the databases and the
  counter store every 60 seconds, and sends the Kubernetes events, all in the cluster root's
  namespaces. It reads its push token from `production-alloy-push-token`, and no Secret of the
  cluster. The Alloy Operator, which the chart runs, manages that namespace alone.
- **Edge:** each platform answers on its own host through a Gateway of its name, on Google's global
  load balancer, which redirects plain HTTP to HTTPS: Studio on `studio.storyverse.fr`, Account on
  `account.storyverse.fr`. Foundation holds each one's address, a TLS 1.2 policy, and a Certificate
  Manager certificate the domain's DNS authorizes. Only the load balancer's ranges reach the
  platforms' pods.
- **Scaling:** an autoscaler absorbs bursts only. It adds or removes one pod a minute at most, and
  removes one only after five minutes below its targets. A workload's maximum moves by pull request,
  which the `Workload autoscaler at its maximum` alert prompts. GenAI's server scales on CPU and on
  its calls in flight, at 60% of `GRPC_MAX_CONCURRENT_CALLS` per pod: GKE reads that gauge from
  each pod's metrics port through an `AutoscalingMetric`. Its maximum of three pods times that cap
  bounds the calls it runs at once, and so its OpenAI spend.
- **Jobs:** each new migrations image runs once as a Job before its server rolls, and so does each
  new database lineage. CronJobs run JSON Keys' key rotation hourly at :10 and Authentication's
  refresh token purge daily at 03:40 UTC, one run at a time, never retried. The suspended
  `maintenance` CronJob holds the template of Authentication's maintenance Jobs, which the
  [setup runbook](runbooks/setup.md) runs.
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
  from 01:00 to 07:00 UTC. A planned downtime holds every upgrade from its start to its end. Google
  collects only system logs and metrics, since Grafana takes every signal.

## Services

| Service        | Workloads                                                                       | Jobs                                                                  |
| -------------- | ------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| JSON Keys      | `grpc`: 2 pods                                                                  | `migrations`, `rotate-keys`, `smoke`, `health`                        |
| Authentication | `rest`: 1 pod, which holds the in-memory rate limits                            | `migrations`, `refresh-token-purge`, `maintenance`, `smoke`, `health` |
| GenAI          | `grpc`: 1 to 3 pods; `sweep`: 1 pod, which checks the generations nobody polled | `migrations`, `smoke`, `health`, `provider-check`                     |
| Studio         | `web`: 1 to 2 pods                                                              |                                                                       |
| Account        | `web`: 1 to 2 pods                                                              |                                                                       |

Each service runs in the namespace of its name. A workload calls another service with a token the
kubelet projects for that service's audience, which the cluster signs. Each service admits only its
named callers: JSON Keys admits Authentication's API, Authentication admits the platforms, and each
admits its own `smoke` identity. Authentication trusts the visitor address the platforms forward,
since only they call it on a visitor's behalf.

Service images come from `ghcr.io/a-novel/*`. Each is pinned as `tag@digest` in its service root's
`terraform.tfvars`, its database image included, and the cluster root reads those pins. Every plan
verifies each release image it changes:

- the release tag's own run built it;
- the release App published that tag as an immutable GitHub Release;
- its version is not below the one deployed.

Before applying, the cluster root's deploy copies the images to Artifact Registry, into the
service's `a-novel-<service>` repository in `europe-west9`, beside the cluster. Each has immutable
tags, and the nodes only read it.

## Databases and backups

Each service with data has a CloudNativePG database named `database` in its namespace: a primary
and a replica on separate nodes. The cluster root's `databases` sizes each one:

| Service        | CPU request | Memory   | Volume | Connections |
| -------------- | ----------- | -------- | ------ | ----------- |
| JSON Keys      | 0.5 vCPU    | 1536 MiB | 10 GiB | 50          |
| Authentication | 0.5 vCPU    | 1536 MiB | 30 GiB | 50          |
| GenAI          | 0.5 vCPU    | 6 GiB    | 20 GiB | 150         |

GenAI's rows hold payloads and responses of up to 24 MiB, so its database has more memory. Each
instance's memory is its limit too, and no instance has a CPU limit. Volumes use `standard-rwo` and
grow in place.

- **Image:** each database's image catalog takes the database image its service root pins, on
  PostgreSQL 18. GenAI preloads `pg_cron`, which runs its retention purge in background workers.
- **Credentials:** CloudNativePG generates them, in the `database-app` Secret, for the database and
  owner `app`.
- **TLS:** each database serves TLS for `database-rw.<service>.svc` from cert-manager's ten-year
  `databases` CA, which keeps its key when renewed. The same CA issues its replica's
  `streaming_replica` certificate, named `streaming-replica.<service>`, which only that database
  maps to the role. The service's pods connect by that name and trust that CA beside the system
  roots.
- **Clients:** only the pods of the service's own workloads and Jobs reach the database's port.
- **Updates** switch over to the replica, which pauses writes for seconds. The deploy waits until
  both instances serve and WAL reaches Barman.

Each database archives its WAL continuously, and takes a base backup from the replica daily at
03:00 UTC, into its own bucket in management, `<prefix>-barman-<service>`. Barman keeps 14 days of
base backups and the WAL they need, and owns their expiry, so the buckets never age-delete live
data. Each bucket is versioned, refuses to delete an object younger than 7 days, and keeps deleted
objects 7 more days. Only that database's Kubernetes service account, `database` in the service's
namespace, writes it, through Workload Identity.

Each database archives under the cluster root's `backup_server_name`, its **lineage**. A new name
recreates every database empty, as [Databases](runbooks/database.md#lineages) describes, and
bootstrap's `retired_barman_lineages` expires the former lineage 15 days after its objects were
written. While a [recovery drill](runbooks/recovery.md) runs, each database it restores reads its
own service's bucket through the `barmanReader` role, and writes none.

## Secrets

Secret containers live in the management project. Humans add their values with `gcloud`, as
[Secrets](runbooks/secrets.md) describes, so OpenTofu never sees them. A service's workloads read
the numeric version its root's `terraform.tfvars` pins, and the add-ons the cluster root's
`addon_secret_versions`. External Secrets copies them into each namespace's `secrets` Secret, as
that namespace's `secrets` identity, which reads only its own service's secrets.

| Secret                                             | Read by                                                                          |
| -------------------------------------------------- | -------------------------------------------------------------------------------- |
| `production-json-keys-app-master-key`              | JSON Keys' server and key rotation                                               |
| `production-genai-openai-api-key`                  | GenAI's server and sweep                                                         |
| `production-alloy-push-token`                      | Alloy                                                                            |
| `production-downtime-discord-webhook`              | `downtime-announcer`, when it posts a planned downtime step                      |
| `production-github-dispatch-{a-novel,a-novel-kit}` | `github-dispatcher`, when it dispatches that org's workflows                     |
| `production-github-plan-key-<org>`                 | `infra-plan`, when it plans the GitHub root                                      |
| `production-github-deploy-key-<org>`               | `infra-github` and `infra-drift`, when they apply or drift-check the GitHub root |
| `production-github-governance-<org>-<name>`        | `infra-github`, when it copies them into the governance environments             |
| `production-grafana{,-cloud}-plan-token`           | `infra-plan`, when it plans the Grafana root                                     |
| `production-grafana{,-cloud}-deploy-token`         | `infra-grafana`, when it applies the Grafana root                                |

## Identities

| Account                                                      | Purpose                                                                                                                                                                                            |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `infra-plan`, `infra-foundation` (management)                | CI: read-only plans and checks, and deployments. In the cluster, `infra-plan` reads every object but Secrets, and `infra-foundation` administers it.                                               |
| `infra-downtime` (management)                                | CI: starts and cancels the planned downtime announcements.                                                                                                                                         |
| `infra-github` (management)                                  | CI: the GitHub root's deploys and sweep, from the `github` environment. It reads the Deploy App keys, the governance secrets and its own state, and holds no Google Cloud role.                    |
| `infra-drift` (management)                                   | CI: the GitHub root's drift check, which reads the Deploy App keys.                                                                                                                                |
| `infra-grafana` (management)                                 | CI: the Grafana root's deploys, from the `grafana` environment. It reads the Grafana write tokens and its own state, and holds no Google Cloud role.                                               |
| `a-novel-cluster-nodes`                                      | The cluster's nodes: GKE's default node role alone, to write their logs and metrics and pull images.                                                                                               |
| Kubernetes service accounts                                  | Each workload runs as its own account in its namespace, such as `rest` or `smoke`. `database` writes its Barman bucket, and `secrets` reads its service's secrets, both through Workload Identity. |
| `<slug>-visual-ci`, `<slug>-visual-maintenance` (management) | The CI of platform-account, platform-studio, platform-template and a-novel-kit/uikit: visual-test evidence in Google Drive, no Cloud Storage access.                                               |
| `downtime-announcer` (management)                            | Runs the planned downtime announcements; reads only the Discord webhook.                                                                                                                           |
| `github-dispatcher`, `github-dispatch-clock` (management)    | The timed workflows' clock: starts the dispatcher, which reads only the dispatch tokens.                                                                                                           |

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
  `allow-resource-deletion`. Even unrefreshed, a plan reads every repository's workflows, one call
  each, from the Plan App's hourly budget that all pull requests share.
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
- **Health checks** run in the cluster: each new image's `smoke-<hash>` Job, which the deploy waits
  on, and each service's `health` CronJob, every five minutes. Grafana's `Scheduled job failing`
  reports a failed run, as [Health checks](runbooks/alerts.md#health-checks) details.
- **Budget alerts** email the cost and operations addresses when the [monthly budget](costs.md)
  reaches a threshold.
- **Logs:** the workloads' logs go to Grafana. Google Cloud Logging keeps the system components'
  logs and the DNS query logs 30 days.
