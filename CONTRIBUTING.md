# Contributing to infra

Workspace setup lives in the [developer guide](https://a-novel-kit.github.io/stack/). Read the
[README](README.md) and [ops basics](docs/ops-basics.md) first.

## Validate locally

The checks need [OpenTofu](https://a-novel-kit.github.io/stack/sysadmins/opentofu#install) at the
pinned version, [TFLint](https://github.com/terraform-linters/tflint), Go and Node. Run CI's main
checks from the repository root, the way CI runs them:

```bash
tofu fmt -check -recursive -diff
tflint --init --config="$PWD/.tflint.hcl" && tflint --recursive --config="$PWD/.tflint.hcl"
for dir in bootstrap environments/production/* environments/recovery $(dirname modules/*/tests | sort -u); do
  tofu -chdir="$dir" init -backend=false -lockfile=readonly && tofu -chdir="$dir" validate && tofu -chdir="$dir" test
done
go test ./internal/hostcredentials/... ./internal/recovery/...
go tool -modfile=golangci-lint.mod golangci-lint run ./...
go tool -modfile=govulncheck.mod govulncheck ./...
node --test '.github/scripts/*.test.mjs'
npx --yes prettier@3.9.10 --no-config --no-editorconfig --check .
```

`tofu test` uses mocked providers and needs no credentials. Each job of `main.yaml` is a required
check:

| Job                                              | Checks                                                                                                         |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `validate-opentofu`                              | Formatting, TFLint, and `validate` and `tofu test` in every root and tested module.                            |
| `lint-repository`                                | Prettier, the Renovate config, the workflow scripts, Go lint, service-root wiring, shell and workflow linters. |
| `test-go`                                        | The host programs, with `-race`.                                                                               |
| `test-backup`                                    | The [backup tests](tests/backup/README.md), inside each service's database image.                              |
| `scan-infrastructure`                            | Trivy on the repository and on both [host tools](docs/runbooks/host-tools.md).                                 |
| `scan-secrets`                                   | gitleaks on the working tree, with the fleet baseline and the allowlist in `.gitleaks.toml`.                   |
| `revoke-deletion-label`, `revoke-downtime-label` | Remove a label a push made stale, so it approves only the commit it was added on.                              |
| `plan-<root>`                                    | The root's real plan, with the read-only identity.                                                             |

## Plan against production

A pure refactor must plan to zero changes. Plan it against the real state with your own
[Google Cloud CLI](https://a-novel-kit.github.io/stack/sysadmins/gcloud#configure) account:

```bash
ROOT=environments/production/foundation
GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)" tofu -chdir="$ROOT" init
GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)" tofu -chdir="$ROOT" plan -refresh=false -lock=false
```

Your account cannot read everything the plan identity can. `-refresh=false` skips refreshing the
managed resources, but the plan still reads the data sources. Stub a data source your account
cannot read in a scratch copy of the root, with its literal value from state, and never in committed
code.

## Rules

- **Put a resource in the root that owns its lifecycle.** A service's runtime goes in its service
  root, shared network and hosts in foundation, and identities and state in bootstrap.
- **Add a module** only for a second caller or a shared security invariant.
- **Wire a new service root where GitHub cannot find it.** `deploy.yaml` and `drift.yaml` find the
  root on disk. `lint-repository` fails until it has a `plan-<root>` job in `main.yaml`, its
  required check, and an option in `roll-database.yaml`. A root with a database host also names the
  Cloud Run services that write to it in `.github/actions/roll`.
- **Inputs go in `terraform.tfvars`.** Secret values never do. Humans add them with `gcloud`, as
  [Secrets](docs/runbooks/secrets.md) describes.
- **Put a rule that can stop or misdeploy production in a tested script.** Workflow steps that call
  `tofu`, `gh`, `gcloud` or `skopeo` stay bash. The decisions around them live in `.github/scripts`,
  as zero-dependency `.mjs` with tests. A port proves itself against the bash it replaces.
- **Pin images and secrets exactly.** Pin an image as the `tag@digest` it was published under, and
  a secret version as a number, never `latest`.
- **Keep production-critical resources protected** with `prevent_destroy`, `deletion_protection` or
  `deletion_policy = "PREVENT"`. A plan that weakens the last two, or `force_destroy`, needs the
  [deletion label](docs/runbooks/deployments.md#deletions-and-weakened-protections). Removing
  `prevent_destroy` changes only the code, so no plan flags it. Say so in the pull request.
- **Change database hosts during a planned downtime.** Their plans need the `allow-downtime` label,
  as [Change a database host](docs/runbooks/database.md#change-a-database-host) describes.
- **Test security contracts, not arguments.** A `tofu test` assertion should state something that
  matters, such as no public IP, internal-only ingress or a pinned secret.
- **Update the runbook** in the same pull request when you change a manual operation.
- **Comment the why.** HCL comments say why, never what the arguments already say.

## Questions

[Open an issue](https://github.com/a-novel/infra/issues) with the root name, the failing check and
sanitized logs.
