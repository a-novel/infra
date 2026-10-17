# A-Novel infrastructure

OpenTofu definitions for A-Novel's production on Google Cloud: projects, network, database hosts,
backups, Cloud Run services and their identities.

[![X (formerly Twitter) Follow](https://img.shields.io/twitter/follow/agorastoryverse)](https://twitter.com/agorastoryverse)
[![Discord](https://img.shields.io/discord/1315240114691248138?logo=discord)](https://discord.gg/rp4Qr8cA)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/a-novel/infra/main.yaml)

## How a change reaches production

Every change is a pull request. CI plans each root with a read-only identity, a few kinds of change
need a maintainer's label, and merging deploys the change: [`deploy.yaml`](.github/workflows/deploy.yaml)
applies the changed roots, rolls the database hosts during their planned downtime, and checks
production health. Nobody applies by hand, except bootstrap during a rebuild from nothing.
[Ops basics](docs/ops-basics.md#from-a-pull-request-to-production) walks through it. To freeze
production, run `gh workflow disable deploy.yaml`.

## Layout

| Path                                     | Contents                                                                     |
| ---------------------------------------- | ---------------------------------------------------------------------------- |
| `bootstrap/`                             | Management project: state bucket, CI identities, secret containers.          |
| `environments/production/foundation`     | Projects, VPC, firewall, database hosts, monitoring, budget.                 |
| `environments/production/json-keys`      | JSON Keys: Cloud Run service and jobs, backup repository, alerts.            |
| `environments/production/authentication` | Authentication: migrations, public REST API, backup repository, alerts.      |
| `environments/recovery`                  | Disposable disaster-recovery host (manual drills only).                      |
| `modules/`                               | `service-runtime`, `backup-repository`, `database-runtime`, `project-shell`. |
| `cmd/`, `internal/`, `builds/`           | The two programs that run on the VMs: TLS loader and restore worker.         |
| `tests/backup/`                          | Offline backup/restore tests inside the real database image.                 |

Each root keeps its production inputs in `terraform.tfvars`. Secret values never live in Git.

## Documentation

Read them in this order to understand the whole setup:

1. [Ops basics](docs/ops-basics.md): the concepts behind this repository, how a change reaches
   production, and how database changes stay safe.
2. [Architecture](docs/architecture.md): what runs where in Google Cloud.
3. [Runbooks](docs/runbooks/README.md): every operation that still needs a human.
4. [Costs](docs/costs.md): what production pays for.

## Contributing

Start with the [developer guide](https://a-novel-kit.github.io/stack/),
then [CONTRIBUTING.md](CONTRIBUTING.md).
