# A-Novel infrastructure

OpenTofu definitions of A-Novel's production on Google Cloud.

[![X (formerly Twitter) Follow](https://img.shields.io/twitter/follow/agorastoryverse)](https://twitter.com/agorastoryverse)
[![Discord](https://img.shields.io/discord/1315240114691248138?logo=discord)](https://discord.gg/rp4Qr8cA)

<hr />

![GitHub repo file or directory count](https://img.shields.io/github/directory-file-count/a-novel/infra)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/a-novel/infra)

![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/a-novel/infra/main.yaml)

## What this is

This repository is A-Novel's production. Every Google Cloud resource the services run on is declared
here, from the project and the network to the cluster and each service's workloads on it. The
code on `master` is what runs. A change reaches production only through a pull request.

Each service gets its own namespace on the cluster, with its own identities and its own database,
and a root that pins its releases. Shared pieces, such as the network and the cluster, live in
foundation, and the CI identities live in bootstrap.

## How a change reaches production

Every change is a pull request. CI plans each root with a read-only identity, and a few kinds of
change need a maintainer's label. Merging deploys the change.
[`deploy.yaml`](.github/workflows/deploy.yaml) applies the roots, and waits on the cluster's
migrations and health checks. Nobody applies by hand, except bootstrap during a rebuild from
nothing. [Ops basics](docs/ops-basics.md#from-a-pull-request-to-production) walks through it.

Disabling `deploy.yaml` [freezes production](docs/runbooks/deployments.md#freeze-production).

## Layout

| Path                                    | Contents                                                                          |
| --------------------------------------- | --------------------------------------------------------------------------------- |
| `bootstrap/`                            | Management project: state bucket, backup buckets, CI identities, secrets.         |
| `environments/production/foundation`    | The workload project, its network, the cluster, the platforms' edges, budget.     |
| `environments/production/cluster`       | Every service's workloads and database, the add-ons and the policies.             |
| `environments/production/<service>`     | One service: its release pins and secret versions, which the cluster root reads.  |
| `environments/production/grafana`       | Grafana's alerts and dashboards, applied only when they change.                   |
| `environments/production/github`        | Both organizations' repositories, rulesets, teams and environments.               |
| `environments/recovery-cluster`         | A recovery drill's throwaway cluster, which reads the restored services' backups. |
| `environments/recovery-database`        | A recovery drill's databases, restored from production's backups and checked.     |
| `modules/cluster-workload`              | One gRPC or HTTP server on the cluster: its identity, pods, Service and scaling.  |
| `modules/database-operator`             | cert-manager, CloudNativePG and its Barman Cloud plugin, for the cluster.         |
| `modules/github-organization`           | One organization's repositories and their config, for the GitHub root.            |
| `modules/smoke-check`                   | The health check every service shares, which the cluster runs.                    |
| `.github/actions/`, `.github/workflows` | The pipeline that plans, deploys and checks production.                           |
| `.github/scripts/`                      | The pipeline's rules that can stop or misdeploy production, with their tests.     |

## Documentation

1. [Ops basics](docs/ops-basics.md): the ideas every runbook relies on.
2. [Architecture](docs/architecture.md): what runs where in Google Cloud.
3. [Runbooks](docs/runbooks/README.md): every operation that still needs a human.
4. [Costs](docs/costs.md): what production pays for.

## Contributing

Start with the [developer guide](https://a-novel-kit.github.io/stack/),
then [CONTRIBUTING.md](CONTRIBUTING.md).
