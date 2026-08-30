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

Complete the repository-only subsections below, then follow
[Set up production](./docs/setup-production.md). After setup, use the
[production operations index](./docs/runbooks/README.md) for deployments, rotations, recovery, and
incidents.

Pull requests and branch pushes are cloud-blind and never deploy. The one-time management bootstrap
is the only local apply and requires an explicitly authorized human. Every later cloud change runs
from reviewed `master` through its protected workflow; agents never run `gcloud` or `tofu apply`.
Keep `PRODUCTION_RELEASES_ENABLED=false` until the launch step explicitly changes it.

The [architecture guide](./docs/architecture.md) explains the lifecycle and security model. The
[release root contract](./environments/production/release/README.md#application-runtime-contract)
defines the human-only Authentication initializer, scheduled JSON Keys rotation, runtime identities,
fixed deployment order, compensation, and receipt boundaries.

### Configure persistent operator inputs

Keep stable, non-secret values used by multiple procedures in the ignored `.envrc`. Start by
setting the two Google Cloud project IDs. The production setup guide tells you when and where to
obtain the four SMTP values; add them to the same file before its SMTP step.

```sh
if [ ! -e .envrc ]; then
  cp .envrc.example .envrc
fi
chmod 600 .envrc
${EDITOR:-vi} .envrc
. ./.envrc
./ops/verify-operator-env.sh
```

Replace the two project-ID placeholders before the final two commands. The verifier prints
`PASS operator project coordinates`. Keep credentials, tokens, secret payloads, plan IDs, receipts,
and incident-specific recovery IDs out of this file. Operators with `direnv` may authorize the same
file after reviewing it; `direnv` is optional.

### Reconcile repository protection

Run these commands from a clean workspace after the repository bootstrap changes have merged:

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

| Required check        | Purpose                                                                                                        |
| --------------------- | -------------------------------------------------------------------------------------------------------------- |
| `validate-opentofu`   | Format, initialize without a backend, validate, run mocked tests, lint HCL and exercise plan-policy fixtures.  |
| `scan-infrastructure` | Fail on high or critical infrastructure, dependency, or secret findings from Trivy.                            |
| `lint-repository`     | Validate workflows, formatting, the release transition, deterministic Renovate behavior, and image provenance. |

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
gh repo view a-novel/infra \
  --json isSecurityPolicyEnabled,securityPolicyUrl \
  --jq '{isSecurityPolicyEnabled,securityPolicyUrl}'

gh api repos/a-novel/infra \
  --jq '{visibility,archived,has_pages,license:.license.spdx_id,security_and_analysis}'
gh api repos/a-novel/infra/private-vulnerability-reporting --jq .enabled
gh api repos/a-novel/infra/releases --jq 'length'
gh api repos/a-novel/infra/tags --jq 'length'
```

The community response should recognize `readme`, `license`, `contributing`, `code_of_conduct`,
`issue_template`, and `pull_request_template`; GitHub's repository query must separately report the
inherited security policy as enabled with a `/security/policy` URL. The repository should be public
and active, report `AGPL-3.0`, have Pages disabled, private vulnerability reporting enabled, secret
scanning and push protection enabled, and return zero releases and zero tags. Infrastructure ships
through protected deployments, not packages; it intentionally has no release, tag, or Pages
workflow. Resolve a missing inherited community file in `a-novel/.github`; do not duplicate it here.

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

| Path                                      | Purpose                                                                        |
| ----------------------------------------- | ------------------------------------------------------------------------------ |
| `deploy/production/images.yaml`           | Enabled components plus stable SemVer image tags and exact digests.            |
| `deploy/production/recovery-cleanup.json` | Inactive-by-default exact authorization for one disposable recovery deletion.  |
| [`ops/`](./ops/README.md)                 | Human operator commands and protected workflow internals.                      |
| `tests/`                                  | Mocked OpenTofu, manifest, Renovate, allowlist, and sanitized plan fixtures.   |
| `docs/architecture.md`                    | Lifecycle, authority, state, delivery, and portability decisions.              |
| `docs/google-cloud.md`                    | Provider resource map, trust boundaries, and official Google Cloud references. |
| `docs/costs/production.md`                | Current unit assumptions and launch/capacity monthly cost ranges.              |
| `docs/runbooks/`                          | Human recovery and deployment procedures with verifiable outcomes.             |

Local modules begin only when two real call sites share a resource shape or one security invariant needs a single implementation. Singleton resources stay in their owning root.

### Plan-output boundary

`ops/plan-summary.sh` reads an OpenTofu JSON plan and emits only counts grouped by action, resource
type, and current or deposed generation. It blocks every deletion, replacement, or state-forget
action on a managed resource, including resource types introduced after the gate was written, and
rejects unknown action combinations. Resource addresses, deposed keys, values, outputs, environment
variables, DSNs, and tokens stay out of public logs.

`ops/tofu-gate.sh` is the protected live OpenTofu entry point. Human operators reach the one local
bootstrap plan/apply through `ops/bootstrap-plan.sh`, which adds commit and checksum custody. The
gate accepts only `bootstrap`, `foundation`,
or `release`; uses the private GCS backend; and keeps raw provider diagnostics in runner-private
files. A failed plan publishes only a fixed reason, resource type, configuration source, and count.
`ops/create-reviewed-plan.sh` uploads the binary saved plan plus non-sensitive custody metadata with
a create-only Cloud Storage precondition. `ops/apply-reviewed-plan.sh` rejects a different commit,
root, recovery state suffix, hash, destructive authorization, consumed plan, or plan older than 24
hours. It consumes custody before applying and proves a zero-change convergence plan afterward. A
failed apply therefore requires a fresh plan. GitHub artifacts and pull-request comments never carry
the plan, state, configuration, or resource values.

### Image updates

The manifest schema accepts only the eight declared database, job, and service image slots. An
enabled component must provide its complete four-image family with exact repository names, complete
stable `vMAJOR.MINOR.PATCH` tags, and `sha256` digests; a disabled component must provide no images.
Branch tags, SHA tags, partial SemVer, prereleases, standalone images, mismatched repositories,
partial families, and undeclared future images fail validation. A deterministic local-registry dry
run proves that Renovate ignores noisy references, groups all four images for one service, separates
service and PostgreSQL majors, and surfaces a digest changed behind an existing tag for blocking
review. Renovate never automerges.

The production manifest selects two reviewed stable launch families, but this code alone still
creates nothing. Foundation seeds empty group-level release metadata and the host remains idle until
protected applies and the first release are authorized. The release root creates recovery jobs only
when both database contracts are enabled together. Once the documented launch switch is true, a
green human merge that changes the manifest starts the protected release workflow; the first launch
and explicit retries can be dispatched manually from `master`. Source GHCR attestations must come
from each producer's `release.yaml` on `master` using a GitHub-hosted runner. That signer policy,
exact tag-to-digest resolution, family SemVer agreement, PostgreSQL major, numeric secret versions,
quota grants, and fresh backups all fail closed before traffic changes. The release receipt records
the exact promoted digests, secret-version identifiers, revisions, migration and rotation
executions, five recovery-verification executions, first-launch initialization evidence, health
gates, commit, and workflow run.

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
JSON Keys IAM allowlist contains only Authentication; release and recovery have no data-plane
invocation grant.
Those definitions have no cloud effect until a protected apply is authorized; deployed
allowed-and-denied path checks remain a release-workflow acceptance gate.

## Contributing

Start with the [developer onboarding guide](https://github.com/a-novel-kit/.github/blob/master/README.md), then read this repository's [contribution guide](./CONTRIBUTING.md).
