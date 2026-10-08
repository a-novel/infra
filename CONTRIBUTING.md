# Contributing to infra

Workspace setup lives in the
[developer onboarding guide](https://github.com/a-novel-kit/.github/blob/master/README.md). Read
[ops basics](docs/ops-basics.md) first.

## Validate locally

CI runs the same checks:

```bash
tofu fmt -recursive
for dir in bootstrap environments/production/* environments/recovery modules/backup-repository modules/database-runtime; do
  tofu -chdir="$dir" init -backend=false && tofu -chdir="$dir" validate && tofu -chdir="$dir" test
done
go test ./internal/...
npx prettier@3.9.9 --no-config --no-editorconfig --check .
```

The real plan appears on your pull request. `tofu test` uses mocked providers and needs no
credentials.

## Rules

- **Put a resource in the root that owns its lifecycle.** A service's runtime goes in its service
  root, shared network and hosts in foundation, and identities and state in bootstrap.
- **Add a module** only for a second caller or a shared security invariant.
- **Inputs go in `terraform.tfvars`.** Secret values never do: add them with `gcloud` (see
  [Secrets](docs/runbooks/secrets.md)).
- **Pin images and secrets exactly.** Images as `tag@digest`, secret versions as numbers, never
  `latest`.
- **Keep production-critical resources protected.** Use `prevent_destroy`, `deletion_protection`
  and `deletion_policy = "PREVENT"`. Relaxing them needs the `allow-resource-deletion` label.
- **Test security contracts, not arguments.** A `tofu test` assertion should state something that
  matters: no public IP, internal-only ingress, a pinned secret.
- **Update the runbook** in the same pull request when you change a manual operation.
- **Comment the why.** HCL comments say why, never what the arguments already say.

## Questions

[Open an issue](https://github.com/a-novel/infra/issues) with the root name, the failing check and
sanitized logs.
