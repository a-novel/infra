# Add a service

This runbook brings a backend service to the production cluster, from its release to its first
recovery drill. narrative-engine is the worked example: each step links the pull request that did
it. A platform also needs its public edge first, as a-novel/infra#1393 gave the account platform
before a-novel/infra#1404 ran it.

The pull requests merge in order, each one deployed before the next.

| Step                                                                       | Who                                       | narrative-engine                      |
| -------------------------------------------------------------------------- | ----------------------------------------- | ------------------------------------- |
| [1. Ready the service](#1-ready-the-service)                               | the service's contributors                | a-novel/service-narrative-engine#1053 |
| [2. Release it](#2-release-it)                                             | core or the service's owners              | v1.0.0, then v1.1.0                   |
| [3. Prepare its backups and registry](#3-prepare-its-backups-and-registry) | a contributor, then ops for secret values | a-novel/infra#1336                    |
| [4. Size the cluster](#4-size-the-cluster)                                 | a contributor, decided by core            | a-novel/infra#1338                    |
| [5. Run the service](#5-run-the-service)                                   | a contributor                             | a-novel/infra#1481                    |
| [6. Check the deploy](#6-check-the-deploy)                                 | a contributor                             | the deploy of a-novel/infra#1481      |
| [7. Add it to the drills](#7-add-it-to-the-drills)                         | a contributor, then ops for the drill     | a-novel/infra#1489                    |

## 1. Ready the service

The cluster runs a service only once it meets the cluster's contracts, in its own repository:

- It serves its API over TLS from the files golib's `REST_TLS_*` or `GRPC_TLS_*` variables name.
- It dials each service it calls over TLS, since the service APIs refuse plaintext.
  narrative-engine dialed plaintext until a-novel/service-narrative-engine#1053 added
  `SERVICE_JSON_KEYS_TLS` and `SERVICE_GENAI_TLS`.
- It checks its callers' service tokens against `SERVICE_TOKEN_ISSUER`, and sends its own, one per
  audience, from the files the kubelet projects.
- It answers the shared health check: a gRPC `Status` RPC, or an HTTP health endpoint that reports
  its dependencies.

## 2. Release it

Core or the service's owners cut the release from **Actions → release** in its repository. Its
`deploy` job dispatches `pin-release.yaml`, which skips a repository infra does not pin yet, so
step 5 writes the first pins by hand. Every later release pins itself, as
[Deployments](deployments.md#release-a-service) shows.

## 3. Prepare its backups and registry

One pull request prepares them. Its deploy applies bootstrap, then foundation:

- **Bootstrap** lists a service with a database in `cluster_databases.services` and in its
  validation, in `barman.tf`, which creates its Barman bucket. Each of its secrets joins
  `secret_definitions`, which creates the container.
- **Foundation** lists it in `releases`, which creates its `a-novel-<service>` image repository
  and lets the nodes read it. A host it reaches on the internet joins `egress_allowlist`, in
  `internet-egress.tf`.

Once it deploys, ops add version 1 of each secret value, as [Secrets](secrets.md#rotate-a-secret)
shows. External Secrets waits for it in step 5. narrative-engine has no secret and reaches no
internet host.

## 4. Size the cluster

The service's budget must fit the node pool beside every other one. Size it from its workloads at
their autoscalers' maximum, a rollout's surge pod, its database's two instances, and its jobs, with
room above. When the budgets outgrow the node pool, core decides its new size, in foundation's
`cluster`. narrative-engine moved the pool to `e2-highmem-4` nodes.

## 5. Run the service

One pull request runs it:

- **Its root,** `environments/production/<service>`: its release pins, written by hand as
  `ghcr.io/a-novel/<repository>/<image>:<tag>@<digest>`, its secret versions, and a test that
  refuses an unpinned image. `main.yaml` gains its `plan-<root>` job.
- **The cluster root:**
  - `namespaces`, `service_budgets`, `release_roles`, and `secrets` for its secrets;
  - `databases`, with `queries/<database>.yaml` and `queries/<database>.sql`, which the tests
    require;
  - `service_tls` for the API it serves;
  - its workloads through `modules/cluster-workload`, with their network policies, in
    `<service>.tf`;
  - for a platform, instead, its entry in `platforms`, in `platforms.tf`. The list runs its `web`
    workload behind its Gateway, and grants it what every platform shares: the calls to
    Authentication, JSON Keys' public keys and profile, and the shared settings, such as
    `PUBLIC_CONSENT_DOMAIN`;
  - its smoke and health checks, in `health_check_targets`;
  - in each service it calls, its API in `SERVICE_TOKEN_CALLERS` and in the network policy;
  - each internet host it reaches in `internet_egress`, for the pods that call it.
- **The Grafana root:** its entry in `alerts`. A stream, or work it runs after answering, goes in
  `latency_ignores`.

In its plans:

- `plan-<root>` fails, since the plan identity cannot create the new root's state lock. It is not
  required yet, so it blocks nothing. The deploy creates the state, and the job becomes required
  once the GitHub root reads the merged `main.yaml`.
- The cluster plan creates everything in the new namespace, and updates in place each service it
  calls, whose pods roll once to admit it.

## 6. Check the deploy

The deploy waits until the database serves and archives its WAL, the migrations Job completes and
the smoke Job passes. It does not wait on the first base backup, which follows within minutes.
Health's **Databases: last base backup** panel shows it.

The Services tab comes once the service holds real data, with the numbers that prove it works, as
[CONTRIBUTING](../../CONTRIBUTING.md#rules) lists.

## 7. Add it to the drills

A pull request lists the service in `recovery.services` in both `recovery-cluster` and
`recovery-database`, its default and its validation. Once its database holds data, ops run one
drill, as [Recovery](recovery.md#run-the-drill) shows.
