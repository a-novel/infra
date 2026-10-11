# Contributing to infra

Workspace setup lives in the
[developer onboarding guide](https://github.com/a-novel-kit/.github/blob/master/README.md). Read
[ops basics](docs/ops-basics.md) first.

## Validate locally

These are CI's main checks, run the same way:

```bash
tofu fmt -check -recursive -diff
tflint --init --config="$PWD/.tflint.hcl" && tflint --recursive --config="$PWD/.tflint.hcl"
for dir in bootstrap environments/production/* environments/recovery $(dirname modules/*/tests | sort -u); do
  tofu -chdir="$dir" init -backend=false -lockfile=readonly && tofu -chdir="$dir" validate && tofu -chdir="$dir" test
done
go test ./internal/hostcredentials/... ./internal/recovery/...
go tool -modfile=golangci-lint.mod golangci-lint run ./...
npx prettier@3.9.10 --no-config --no-editorconfig --check .
```

`tofu test` uses mocked providers and needs no credentials. CI also runs the Go tests with `-race`,
the [backup tests](tests/backup/README.md) inside both database images, the Renovate config
validator, shellcheck, actionlint, zizmor and a Trivy scan, which also builds both
[host tools](docs/runbooks/host-tools.md). The real plans appear on your pull request.

## Rules

- **Put a resource in the root that owns its lifecycle.** A service's runtime goes in its service
  root, shared network and hosts in foundation, and identities and state in bootstrap.
- **Add a module** only for a second caller or a shared security invariant.
- **Inputs go in `terraform.tfvars`.** Secret values never do: add them with `gcloud` (see
  [Secrets](docs/runbooks/secrets.md)).
- **Pin images and secrets exactly.** Service and database images as `tag@digest`, host tools by
  digest alone, secret versions as numbers, never `latest`.
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
