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

The repository currently has no cloud apply workflow. Google Cloud access and protected deployment environments will be introduced with the bootstrap root. Until that reviewed change lands, the setup below is the complete operator work.

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

| Root                                                                                    | Ownership                                                                                               |
| --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| [`bootstrap/`](./bootstrap/README.md)                                                   | Stable management project, remote state, recovery storage, GitHub federation, and secret metadata.      |
| [`environments/production/foundation/`](./environments/production/foundation/README.md) | Long-lived workload project, IAM, network, database host, backups, monitoring, and service definitions. |
| [`environments/production/release/`](./environments/production/release/README.md)       | Routine image, job, revision, traffic, and database-template deployment.                                |

The three names form a security allowlist. Add a root only when a new lifecycle and automation authority require an independent state boundary.

### Supporting paths

| Path                            | Purpose                                                                        |
| ------------------------------- | ------------------------------------------------------------------------------ |
| `deploy/production/images.yaml` | Enabled components plus stable SemVer image tags and exact digests.            |
| `ops/`                          | Small, tested CI and operator shims shared by the roots.                       |
| `tests/`                        | Mocked OpenTofu, manifest-schema, allowlist, and sanitized plan fixtures.      |
| `docs/architecture.md`          | Lifecycle, authority, state, delivery, and portability decisions.              |
| `docs/google-cloud.md`          | Provider resource map, trust boundaries, and official Google Cloud references. |
| `docs/runbooks/`                | Human recovery and deployment procedures with verifiable outcomes.             |

Local modules begin only when two real call sites share a resource shape or one security invariant needs a single implementation. Singleton resources stay in their owning root.

### Plan-output boundary

`ops/plan-summary.sh` reads an OpenTofu JSON plan and emits only counts grouped by action and resource type. It blocks deletion or replacement of protected state, project, identity, secret, bucket, and database-disk resources. Resource addresses, values, outputs, environment variables, DSNs, and tokens stay out of public logs.

Opaque production plans will live in private, versioned Google Cloud storage when the protected apply workflow lands. GitHub artifacts and pull-request comments never carry them.

### Image updates

The manifest schema accepts complete stable tags such as `v2.5.0` plus a `sha256` digest. Branch tags and prereleases fail validation. Renovate groups each service's image family so one green merge represents one deployment candidate.

The bootstrap manifest keeps both services disabled until their runtime resources and verified image digests land. Merging this repository skeleton cannot deploy an application or create a cloud resource.

### Portability boundary

Application deliverables remain OCI images using HTTP, gRPC, PostgreSQL, SMTP, environment configuration, health endpoints, and graceful termination. Those contracts can move to another conforming runtime.

Google networking, IAM, storage, and managed runtime resources remain explicit OpenTofu resources. The repository does not maintain parallel Kubernetes, Helm, Knative, or provider-neutral wrappers before a second runtime exists.

### Network boundary

The [Google Cloud provider guide](./docs/google-cloud.md#network-trust-model) defines the acceptance contract for later resource changes. PostgreSQL will have no external IP, public frontend, or public firewall path. Private gRPC will use internal Cloud Run ingress plus an exact IAM invoker allowlist. A gRPC server necessarily accepts approved internal RPCs; it remains unreachable to public and unauthenticated clients.

Ingress and egress are independent. JSON Keys starts with private-only egress and no public internet path. Authentication uses private VPC routes for internal destinations and managed TLS egress for SMTP. A future private GenAI gRPC service can use that public-TLS egress profile for LLM APIs without opening its ingress.

These properties are targets, not current enforcement: this bootstrap contains no network, firewall, Cloud Run, IAM, or VM resources. Each property becomes enforceable with its owning resource, mocked assertion, protected apply, and post-apply verification.

## Contributing

Start with the [developer onboarding guide](https://github.com/a-novel-kit/.github/blob/master/README.md), then read this repository's [contribution guide](./CONTRIBUTING.md).
