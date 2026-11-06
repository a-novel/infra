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
for dir in bootstrap environments/production/* environments/recovery* $(dirname modules/*/tests | sort -u); do
  tofu -chdir="$dir" init -backend=false -lockfile=readonly && tofu -chdir="$dir" validate && tofu -chdir="$dir" test
done
node --test '.github/scripts/*.test.mjs'
npx --yes prettier@3.9.10 --no-config --no-editorconfig --check .
```

`tofu test` uses mocked providers and needs no credentials. Each job of `main.yaml` is a required
check:

| Job                                              | Checks                                                                                                |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| `validate-opentofu`                              | Formatting, TFLint, and `validate` and `tofu test` in every root and tested module.                   |
| `lint-repository`                                | Prettier, the Renovate config, the workflow scripts, service-root wiring, shell and workflow linters. |
| `scan-infrastructure`                            | Trivy on the repository.                                                                              |
| `scan-secrets`                                   | gitleaks on the working tree, with the fleet baseline and the allowlist in `.gitleaks.toml`.          |
| `revoke-deletion-label`, `revoke-downtime-label` | Remove a label a push made stale, so it approves only the commit it was added on.                     |
| `plan-<root>`                                    | The root's real plan, with the read-only identity.                                                    |

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

- **Put a resource in the root that owns its lifecycle.** A service's workloads and database go in
  the cluster root, its release pins and secret versions in its service root, the network and the
  cluster in foundation, and identities, state and backup buckets in bootstrap.
- **Add a module** only for a second caller or a shared security invariant.
- **Wire a new service where the code cannot find it.** `deploy.yaml`, `drift.yaml` and
  `downtime.yaml` find its root on disk. `lint-repository` fails until the root has a `plan-<root>`
  job in `main.yaml`, its required check. The cluster root names its namespace, release roles and
  budget, foundation its release repository, and bootstrap its Barman bucket when it has a
  database. [Add a service](docs/runbooks/new-service.md) gives the order.
- **Watch a new service in Grafana, and keep watching it as it changes.** Errors, Health and
  Performance cover a workload once it runs in its namespace and exports spans. The rest comes with
  the service:
  - its thresholds in the Grafana root's `alerts`, with a `p95_seconds` above its measured p95 and
    `latency_ignores` for its streams and the work it runs after a request, such as an email send;
  - its database's queries in the cluster root's `queries/<database>.yaml`, and their columns in
    `queries/<database>.sql`, which grants them to CloudNativePG's exporter;
  - its tab in `dashboards/services.json`, with the numbers that prove it works: what it holds, what
    it does each hour and what it refuses;
  - a `data_rules` alert for each promise that would fail silently, with its row in the
    [alerts runbook](docs/runbooks/alerts.md#grafana-alerts).

  A release that renames a span, an attribute, a table or a column updates them in the same train.
  A stale trace panel reads empty, and a grant on a dropped column fails the deploy.

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
- **Upgrade a PostgreSQL major during a planned downtime.** Its plan needs the `allow-downtime`
  label, as [PostgreSQL major upgrades](docs/runbooks/database.md#postgresql-major-upgrades)
  describes.
- **Test security contracts, not arguments.** A `tofu test` assertion should state something that
  matters, such as no public IP, a default-deny network policy or a pinned secret.
- **Update the runbook** in the same pull request when you change a manual operation.
- **Comment the why.** HCL comments say why, never what the arguments already say.

## Code license

The repository's copyrightable source code owned by the project licensor is released under [RPL-1.5](LICENSE). See [NOTICE.md](NOTICE.md) for the current licensor, source-file notice, and history of licensing.

## Contributor agreement

Before submitting a contribution for possible inclusion in an official A-Novel repository, please review [CLA.md](CLA.md). The project maintainer may require a duly signed individual or corporate Contributor License Agreement before accepting the contribution. A pull request, checkbox, or signed-off commit by itself does not replace a legally valid CLA signature.

If your contribution was developed for an employer or customer, or includes third-party material, ensure that you have permission to grant the rights in the CLA and disclose any third-party license terms.

The CLA gives the maintainer additional rights to use accepted contributions, including proprietary relicensing where lawful. It does not change the RPL-1.5 license of public releases or bind independent fork maintainers who have not signed it.

## Submitting changes

1. Open an issue or pull request describing the proposed change.
2. Identify any incorporated third-party material and applicable notices.
3. Where requested, complete a signed CLA and identify the relevant GitHub identity, repository and PR/commit.
4. Maintain copyright attribution and the RPL-1.5 Exhibit A notices required by the repository license.

Project maintainers will separately record signatures and match them to accepted PRs or commits. GitHub does not automatically execute or validate this agreement merely because the file exists in the repository.

## Questions

[Open an issue](https://github.com/a-novel/infra/issues) with the root name, the failing check and
sanitized logs.
