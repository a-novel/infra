# A-Novel infrastructure

OpenTofu definitions of A-Novel's production on Google Cloud.

[![X (formerly Twitter) Follow](https://img.shields.io/twitter/follow/agorastoryverse)](https://twitter.com/agorastoryverse)
[![Discord](https://img.shields.io/discord/1315240114691248138?logo=discord)](https://discord.gg/rp4Qr8cA)

<hr />

![GitHub go.mod Go version](https://img.shields.io/github/go-mod/go-version/a-novel/infra)
![GitHub repo file or directory count](https://img.shields.io/github/directory-file-count/a-novel/infra)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/a-novel/infra)

![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/a-novel/infra/main.yaml)

## What this is

This repository is A-Novel's production. Every Google Cloud resource the services run on is declared
here, from the projects and the network to each service's database host and Cloud Run workloads. The
code on `master` is what runs. A change reaches production only through a pull request.

Each service gets its own root, its own identities and its own database. Shared pieces, such as the
network and the trust-zone projects, live in foundation, and the CI identities live in bootstrap.

## How a change reaches production

Every change is a pull request. CI plans each root with a read-only identity, and a few kinds of
change need a maintainer's label. Merging deploys the change.
[`deploy.yaml`](.github/workflows/deploy.yaml) applies the roots, rolls the database hosts during
their planned downtime, and checks production health. Nobody applies by hand, except bootstrap
during a rebuild from nothing. [Ops basics](docs/ops-basics.md#from-a-pull-request-to-production)
walks through it.

Disabling `deploy.yaml` [freezes production](docs/runbooks/deployments.md#freeze-production).

## Layout

| Path                                    | Contents                                                                         |
| --------------------------------------- | -------------------------------------------------------------------------------- |
| `bootstrap/`                            | Management project: state bucket, CI identities, secret containers.              |
| `environments/production/foundation`    | Projects, VPC, firewall, database hosts, monitoring, budget.                     |
| `environments/production/<service>`     | One service: its Cloud Run workloads, identities, backup repository and alerts.  |
| `environments/production/cluster`       | The cluster's namespaces, add-ons and policies, applied only when they change.   |
| `environments/production/sentry`        | Sentry's projects and configuration, applied only when they change.              |
| `environments/recovery`                 | Disposable disaster-recovery host, for manual drills.                            |
| `environments/recovery-cluster`         | A cluster drill's disposable cluster, which reads one service's backups.         |
| `environments/recovery-database`        | A cluster drill's database, restored from production's backups.                  |
| `modules/service-runtime`               | A service's identities, image repositories and alert channel in one project.     |
| `modules/smoke-check`                   | A private service's smoke job, and the health check every service shares.        |
| `modules/database-runtime`              | A database host's boot configuration and host scripts.                           |
| `modules/backup-repository`             | A service's pgBackRest repository VM and its backup alerts.                      |
| `modules/project-shell`                 | An empty trust-zone project, for foundation.                                     |
| `modules/database-operator`             | cert-manager, CloudNativePG and its Barman Cloud plugin, for the cluster.        |
| `modules/cluster-workload`              | One gRPC workload on the cluster: its identity, Deployment, Service and scaling. |
| `cmd/`, `internal/`, `builds/`          | The two programs that run on the VMs: the TLS loader and the restore worker.     |
| `.github/actions/`, `.github/workflows` | The pipeline that plans, deploys and checks production.                          |
| `.github/scripts/`                      | The pipeline's rules that can stop or misdeploy production, with their tests.    |
| `tests/backup/`                         | Offline backup and restore tests inside the real database images.                |

## Documentation

1. [Ops basics](docs/ops-basics.md): the ideas every runbook relies on.
2. [Architecture](docs/architecture.md): what runs where in Google Cloud.
3. [Runbooks](docs/runbooks/README.md): every operation that still needs a human.
4. [Costs](docs/costs.md): what production pays for.

## Contributing

Start with the [developer guide](https://a-novel-kit.github.io/stack/),
then [CONTRIBUTING.md](CONTRIBUTING.md).
