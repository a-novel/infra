# Contributing to infra

Workspace setup lives in the
[developer guide](https://a-novel-kit.github.io/stack/). Read
[ops basics](docs/ops-basics.md) first.

## Validate locally

[Install OpenTofu](https://a-novel-kit.github.io/stack/sysadmins/opentofu#install) at the pinned
version. These are CI's main checks, run the same way:

```bash
tofu fmt -check -recursive -diff
tflint --init --config="$PWD/.tflint.hcl" && tflint --recursive --config="$PWD/.tflint.hcl"
for dir in bootstrap environments/production/* environments/recovery $(dirname modules/*/tests | sort -u); do
  tofu -chdir="$dir" init -backend=false -lockfile=readonly && tofu -chdir="$dir" validate && tofu -chdir="$dir" test
done
go test ./internal/hostcredentials/... ./internal/recovery/...
go tool -modfile=golangci-lint.mod golangci-lint run ./...
node --test '.github/scripts/*.test.mjs'
npx prettier@3.9.10 --no-config --no-editorconfig --check .
```

`tofu test` uses mocked providers and needs no credentials. Each job of `main.yaml` is a required
check:

| Job                   | Checks                                                                                                         |
| --------------------- | -------------------------------------------------------------------------------------------------------------- |
| `validate-opentofu`   | Formatting, TFLint, and `validate` and `tofu test` in every root and tested module.                            |
| `lint-repository`     | Prettier, the Renovate config, the workflow scripts, Go lint, service-root wiring, shell and workflow linters. |
| `test-go`             | The host programs, with `-race`.                                                                               |
| `test-backup`         | The [backup tests](tests/backup/README.md), inside each database image.                                        |
| `scan-infrastructure` | Trivy on the repository and on both [host tools](docs/runbooks/host-tools.md).                                 |
| `plan-<root>`         | The root's real plan, with the read-only identity.                                                             |

## Rules

- **Put a resource in the root that owns its lifecycle.** A service's runtime goes in its service
  root, shared network and hosts in foundation, and identities and state in bootstrap.
- **Add a module** only for a second caller or a shared security invariant.
- **Inputs go in `terraform.tfvars`.** Secret values never do: add them with `gcloud` (see
  [Secrets](docs/runbooks/secrets.md)).
- **Put a rule that can stop or misdeploy production in a tested script.** Workflow steps that call
  `tofu`, `gh`, `gcloud` or `skopeo` stay bash. The decisions around them live in `.github/scripts`,
  as zero-dependency `.mjs` with tests. A port proves itself against the bash it replaces.
- **Pin images and secrets exactly.** Images as the `tag@digest` they were published under, copies
  in Artifact Registry by digest, secret versions as numbers, never `latest`.
- **Keep production-critical resources protected.** Use `prevent_destroy`, `deletion_protection`
  and `deletion_policy = "PREVENT"`. A plan that weakens `deletion_protection`, `deletion_policy` or
  `force_destroy` needs the `allow-resource-deletion` label. Removing `prevent_destroy` changes only
  the code, so no plan flags it: say so in the pull request.
- **Change database hosts during a planned downtime.** Their plans need the `allow-downtime` label;
  see [Change a database host](docs/runbooks/database.md#change-a-database-host).
- **Test security contracts, not arguments.** A `tofu test` assertion should state something that
  matters: no public IP, internal-only ingress, a pinned secret.
- **Update the runbook** in the same pull request when you change a manual operation.
- **Comment the why.** HCL comments say why, never what the arguments already say.

## Questions

[Open an issue](https://github.com/a-novel/infra/issues) with the root name, the failing check and
sanitized logs.
