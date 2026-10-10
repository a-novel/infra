# Agora infrastructure

OpenTofu definitions for Agora's production on Google Cloud: projects, network, database hosts,
backups, Cloud Run services and their identities.

[![X (formerly Twitter) Follow](https://img.shields.io/twitter/follow/agorastoryverse)](https://twitter.com/agorastoryverse)
[![Discord](https://img.shields.io/discord/1315240114691248138?logo=discord)](https://discord.gg/rp4Qr8cA)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/a-novel/infra/main.yaml)

## How a change reaches production

1. **Open a pull request.** CI validates every root and posts a read-only `tofu plan` per root in
   the job summary.
2. **Review the plan.** A plan that deletes, replaces or unprotects anything fails until a
   maintainer adds the `allow-resource-deletion` label. A push removes it, so each head's plans
   get their own approval.
3. **Merge.** [`deploy.yaml`](.github/workflows/deploy.yaml) applies the roots the merge changed:
   `bootstrap → foundation → services in parallel`, then checks production health.

Nobody applies by hand. To freeze production, run `gh workflow disable deploy.yaml`.

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

- [Ops basics](docs/ops-basics.md): the concepts behind this repository, and why it is laid out
  this way.
- [Architecture](docs/architecture.md): what runs where in Google Cloud.
- [Runbooks](docs/runbooks/README.md): every operation that stays manual.
- [Costs](docs/costs.md).

## Contributing

Start with the [developer onboarding guide](https://github.com/a-novel-kit/.github/blob/master/README.md),
then [CONTRIBUTING.md](CONTRIBUTING.md).
