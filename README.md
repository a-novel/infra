# Agora infrastructure

OpenTofu and GitOps definitions for Agora's low-cost Google Cloud production environment.

[![X (formerly Twitter) Follow](https://img.shields.io/twitter/follow/agorastoryverse)](https://twitter.com/agorastoryverse)
[![Discord](https://img.shields.io/discord/1315240114691248138?logo=discord)](https://discord.gg/rp4Qr8cA)

<hr />

![GitHub repo file or directory count](https://img.shields.io/github/directory-file-count/a-novel/infra)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/a-novel/infra)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/a-novel/infra/main.yaml)

## What this is

This repository defines the Google Cloud resources and deployment controls for Agora. The first production slice is designed to serve JSON Keys over private gRPC and Authentication over public HTTPS, backed by two PostgreSQL containers on one private, preserved data plane.

The repository separates stable recovery resources, long-lived production infrastructure, and routine application deployments into three OpenTofu roots. That split keeps each automation identity limited to the resources it owns.

The design is a small Google Cloud landing zone built from established infrastructure-as-code, least-privilege, immutable-artifact, and reviewed-deployment practices. The [architecture guide](./docs/architecture.md) records those principles and the deliberate limits that keep the platform proportionate to Agora's current scale.

## Setup

Pull requests are cloud-blind. They receive a read-only repository token and run formatting, validation, mocked OpenTofu tests, static security analysis, and manifest checks. They receive no Google identity, protected environment, or secret payload.

The repository currently has no cloud apply workflow. Bootstrap, the workload foundation, the
private stateful PostgreSQL host, logical backup and restore jobs, daily disk snapshots, recovery
monitoring, four application jobs, the private JSON Keys and public Authentication services, and the
narrow release-metadata command are defined, but merging or validating them creates nothing.
Bootstrap's one-time initial application remains a human-only exception performed from `master`
after explicit approval; agents never run `gcloud` or `tofu apply`. Foundation and release must wait
for their protected workflows and cannot be applied from a branch or an operator checkout.

### Bootstrap Google Cloud only after explicit authorization

Use [Bootstrap and verify the management plane](./docs/runbooks/bootstrap-management-plane.md) after
this change is merged and an operator is authorized to create resources. It contains the exact
standalone or organization/folder project commands, billing and API prerequisites, temporary access,
GitHub environments, local first plan/apply, remote-state migration, WIF/IAM verification,
organization-policy option, broad-access removal, expected safe output, and partial-failure recovery.

Do not improvise a shorter setup in the console. The only unavoidable console actions are creating a
billing account when none exists, securing the human account and recovery codes, and disabling GitHub
administrator bypass for the two high-authority environments where the documented public API does
not expose that switch. Every resulting control has an independent command-line verification.

### Prepare the workload foundation only after bootstrap is verified

Use [Provision and verify the workload foundation](./docs/runbooks/provision-workload-foundation.md)
to choose the immutable workload project ID, record the billing and parent prerequisites, configure
the future protected environment, and verify the resulting project, private routing, identities,
registry, database host, quotas, budget, monitoring, and logging. The runbook contains separate
organization/folder and standalone-project paths and the temporary Owner-removal step required after
project creation. The [PostgreSQL host runbook](./docs/runbooks/operate-postgresql-host.md) owns the
host-specific readiness, isolation, capacity, maintenance, and rollback checks.

The [PostgreSQL backup and restore runbook](./docs/runbooks/backup-and-restore-postgresql.md) owns
recovery activation, the first-write gate, four-hour logical backups, monthly clean restores, the
daily snapshot contract, retention locking, alert response, RPO/RTO evidence, and the PITR decision
thresholds. Read it before enabling either database release. Its commands remain stop-gated until
the protected workflows exist and resource creation is explicitly authorized.

That runbook is preparation only until `.github/workflows/foundation.yaml` exists on `master` and a
maintainer explicitly authorizes resource creation. Do not run its mutating Google Cloud commands or
any `tofu apply` while the repository is still in this state.

### Reconcile repository protection after this bootstrap merges

Run these commands from a clean workspace after both bootstrap pull requests have merged:

```bash
cd ~/git-projects/a-novel
git switch master
git pull --ff-only

a-novel core sync --allow=a-novel/infra
cd app/infra
git switch master
git pull --ff-only

a-novel repo update --dry-run
a-novel repo update
a-novel repo update --dry-run
```

Review the first dry run before approving the interactive update. It should add the three `main.yaml` job contexts to the `master` ruleset and set GitHub default Actions code scanning to `not-configured`; the required Zizmor audit replaces that overlapping check:

| Required check        | Purpose                                                                                                       |
| --------------------- | ------------------------------------------------------------------------------------------------------------- |
| `validate-opentofu`   | Format, initialize without a backend, validate, run mocked tests, lint HCL and exercise plan-policy fixtures. |
| `scan-infrastructure` | Fail on high or critical infrastructure, dependency, or secret findings from Trivy.                           |
| `lint-repository`     | Validate workflows, Renovate configuration, formatting, and the production image schema.                      |

`a-novel repo update --dry-run` renders the complete desired write set; it is not a live-state diff and therefore remains non-empty after reconciliation. On both dry runs, its header must list exactly `epic-freeze`, `lint-repository`, `merge-gate`, `scan-infrastructure`, and `validate-opentofu` as required checks.

Verify the live `master` ruleset independently after the update:

```bash
gh api repos/a-novel/infra/rulesets \
  --jq '.[] | select(.name == "master") | .id' \
  | xargs -I{} gh api repos/a-novel/infra/rulesets/{} \
    --jq '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | sort'
```

The result must be `["epic-freeze","lint-repository","merge-gate","scan-infrastructure","validate-opentofu"]`.

Confirm the duplicate default Actions analysis is disabled:

```bash
gh api repos/a-novel/infra/code-scanning/default-setup --jq .state
```

The result must be `not-configured`. Trivy and Zizmor remain required and blocking.

### Give Renovate access when the organization installation is selective

The organization Renovate app needs read/write access to `a-novel/infra` to open dependency pull requests. If the installation is configured for selected repositories, an organization owner must add `a-novel/infra` in **Organization settings → GitHub Apps → Renovate → Configure**.

Verify the installation after Renovate's next run:

```bash
gh issue list \
  --repo a-novel/infra \
  --search 'Dependency Dashboard in:title' \
  --json number,title,url
```

The result should contain one Dependency Dashboard. Renovate pull requests still pass the same required checks and merge controls as contributor pull requests.

### Verify the public community profile

The repository keeps its own README, contribution guide, and AGPL-3.0 license. The organization supplies the [Code of Conduct](https://github.com/a-novel/.github/blob/master/CODE_OF_CONDUCT.md), [security policy](https://github.com/a-novel/.github/blob/master/SECURITY.md), issue forms, and pull-request template.

```bash
gh api repos/a-novel/infra/community/profile \
  --jq '{health_percentage, files: (.files | keys)}'
```

The response should recognize `readme`, `license`, `contributing`, `code_of_conduct`, `security`, `issue_template`, and `pull_request_template`. Resolve a missing inherited file in `a-novel/.github`; do not duplicate it here.

### Prepare a local checkout

Install the repository-only validation dependencies, then exercise every root:

```bash
pnpm install --frozen-lockfile

./ops/check-root.sh bootstrap
./ops/check-root.sh foundation
./ops/check-root.sh release

./tests/ops_test.sh
pnpm lint
pnpm test
```

`check-root.sh` accepts only `bootstrap`, `foundation`, or `release`. It initializes with `-backend=false` and runs mocked tests, so this local path does not authenticate to or query Google Cloud.

## Repository reference

### Roots

| Root                                                                                    | Ownership                                                                                          |
| --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| [`bootstrap/`](./bootstrap/README.md)                                                   | Stable management project, remote state, recovery storage, GitHub federation, and secret metadata. |
| [`environments/production/foundation/`](./environments/production/foundation/README.md) | Long-lived workload project, IAM, network, database host, backups, and monitoring controls.        |
| [`environments/production/release/`](./environments/production/release/README.md)       | Routine image, job, revision, traffic, and database-container deployment.                          |

The three names form a security allowlist. Add a root only when a new lifecycle and automation authority require an independent state boundary.

### Supporting paths

| Path                            | Purpose                                                                        |
| ------------------------------- | ------------------------------------------------------------------------------ |
| `deploy/production/images.yaml` | Enabled components plus stable SemVer image tags and exact digests.            |
| `ops/`                          | Small, tested CI and operator shims shared by the roots.                       |
| `tests/`                        | Mocked OpenTofu, manifest-schema, allowlist, and sanitized plan fixtures.      |
| `docs/architecture.md`          | Lifecycle, authority, state, delivery, and portability decisions.              |
| `docs/google-cloud.md`          | Provider resource map, trust boundaries, and official Google Cloud references. |
| `docs/costs/production.md`      | Current unit assumptions and launch/capacity monthly cost ranges.              |
| `docs/runbooks/`                | Human recovery and deployment procedures with verifiable outcomes.             |

Local modules begin only when two real call sites share a resource shape or one security invariant needs a single implementation. Singleton resources stay in their owning root.

### Plan-output boundary

`ops/plan-summary.sh` reads an OpenTofu JSON plan and emits only counts grouped by action and resource
type. It blocks every deletion, replacement, or state-forget action on a managed resource, including
resource types introduced after the gate was written, and rejects unknown action combinations.
Resource addresses, values, outputs, environment variables, DSNs, and tokens stay out of public
logs.

Opaque production plans will live in private, versioned Google Cloud storage when the protected apply workflow lands. GitHub artifacts and pull-request comments never carry them.

### Image updates

The manifest schema accepts only the eight declared database, job, and service image slots. An
enabled component must provide its complete four-image family with exact repository names, complete
stable tags such as `v2.5.0`, and `sha256` digests; a disabled component must provide no images.
Branch tags, prereleases, standalone images, mismatched repositories, partial families, and
undeclared future images fail validation. Renovate groups each service's image family so one green
merge represents one deployment candidate.

The production manifest keeps both services disabled until the recovery resources, runtime
resources, and verified image digests are ready. Foundation therefore seeds empty group-level
release metadata and the host would remain idle. The release root creates recovery jobs only when
both database contracts are enabled together. The tested deployment helper has no caller until the
protected workflow lands. Merging this change cannot deploy an application, run a backup, or create
a cloud resource.

### Portability boundary

Application deliverables remain OCI images using HTTP, gRPC, PostgreSQL, SMTP, environment configuration, health endpoints, and graceful termination. Those contracts can move to another conforming runtime.

Google networking, IAM, storage, and managed runtime resources remain explicit OpenTofu resources. The repository does not maintain parallel Kubernetes, Helm, Knative, or provider-neutral wrappers before a second runtime exists.

### Network boundary

The [Google Cloud provider guide](./docs/google-cloud.md#network-trust-model) defines the acceptance contract for later resource changes. PostgreSQL will have no external IP, public frontend, or public firewall path. Private gRPC will use internal Cloud Run ingress plus an exact IAM invoker allowlist. A gRPC server necessarily accepts approved internal RPCs; it remains unreachable to public and unauthenticated clients.

Ingress and egress are independent. JSON Keys starts with private-only egress and no public internet path. Authentication uses private VPC routes for internal destinations and managed TLS egress for SMTP. A future private GenAI gRPC service can use that public-TLS egress profile for LLM APIs without opening its ingress.

The foundation code now enforces the VPC, subnet, restricted Google routes, firewall policy, private
DNS, no-external-IP stateful database group, preserved disk/address, inbound-only database container
networking, recovery identities, daily disk snapshots, and native recovery alerts in mocked tests.
The release code gives backup and private application jobs only reviewed private database/API
egress, gives restore jobs no database route or secret, sends every JSON Keys service connection
through the deny-by-default VPC, and gives Authentication only split private VPC plus managed public
SMTP egress. It deliberately provisions no NAT, router, connector, load balancer, or public IP. The
JSON Keys IAM allowlist contains only Authentication and protected release/recovery identities.
Those definitions still have no cloud effect until a protected apply is authorized; deployed
allowed-and-denied path checks remain a release-workflow acceptance gate.

## Contributing

Start with the [developer onboarding guide](https://github.com/a-novel-kit/.github/blob/master/README.md), then read this repository's [contribution guide](./CONTRIBUTING.md).
