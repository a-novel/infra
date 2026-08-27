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

Pull requests are cloud-blind. They receive a read-only repository token and run formatting,
validation, mocked OpenTofu tests, static security analysis, and manifest checks. They receive no
Google identity, protected environment, secret payload, or production state.

Pull requests and branch pushes never deploy. A merge to `master` that changes only the reviewed
production image manifest starts the protected release workflow after the fail-safe repository
variable `PRODUCTION_RELEASES_ENABLED` is explicitly set to `true`. Until bootstrap, release inputs,
and recovery checks are complete, a missing or false switch skips the job before its protected
environment is entered. Foundation, recovery, rollback, and the first post-bootstrap release retain
explicit manual entry points. A shared concurrency lock serializes every production writer.

Foundation changes use separate plan and apply runs: the first stores an opaque saved plan in private
Google Cloud Storage for 24 hours, and the second applies that exact commit-, root-, state-, and
hash-bound plan after environment approval. Routine releases use a fixed deployment graph and an
immutable success receipt; failures compensate to the prior receipt while backward-compatible
migrations remain. Recovery can rebuild only into a new disposable project. The sole scheduled
cloud workflow stays read-only: it inspects drift daily and checks Authentication plus its exact
dependencies every three hours after production releases are enabled.

The bootstrap root's one-time initial apply remains a human-only exception performed from `master`
after explicit approval. After that first trust anchor exists, bootstrap and foundation changes use
the protected workflow. Agents never run `gcloud` or `tofu apply` for this repository.

Before the application contract can be enabled, the foundation input must name at least one `user:`
or `group:` Authentication initializer. Foundation gives only those humans the initializer service
identity, its Resource Manager tag, and a conditional invocation grant. Routine automation cannot
use that identity or tag, change Cloud Run IAM, invoke the initializer, or override an execution.
The human provisions the one-time job in two phases, the first release records its exact successful
run, and the job is then deleted. JSON Keys rotation is separate: release runs it once after
migration, then an hourly authenticated schedule evaluates the idempotent job. The
[release root contract](./environments/production/release/README.md#application-runtime-contract)
documents the exact IAM and runtime-identity boundaries.

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
the protected input bundle, review and apply an exact private plan, and verify the resulting project, private routing, identities,
registry, database host, quotas, budget, monitoring, and logging. The runbook contains separate
organization/folder and standalone-project paths and the temporary Owner-removal step required after
project creation. The [PostgreSQL host runbook](./docs/runbooks/operate-postgresql-host.md) owns the
host-specific readiness, isolation, capacity, maintenance, and rollback checks.

The [PostgreSQL backup and restore runbook](./docs/runbooks/backup-and-restore-postgresql.md) owns
recovery activation, the first-write gate, four-hour logical backups, monthly clean restores, the
daily snapshot contract, retention locking, alert response, RPO/RTO evidence, and the PITR decision
thresholds. Read it before enabling either database release. Its commands remain stop-gated until
resource creation is explicitly authorized.

The [production alert runbook](./docs/runbooks/respond-to-alerts.md) owns the two human notification
destinations, eight native application/database policies, the bounded GitHub synthetic health
check, budget escalation, workflow failures, and channel-delivery verification. It deliberately
uses Google and GitHub signals already present instead of adding a pager, bot, custom metric, or
monitoring agent.

After merging the cron definition, the GitHub account associated with that schedule must enable
email or web Actions notifications in **GitHub settings → Notifications → System → Actions**. Wait
for one successful three-hour health run to verify delivery, then select failed-workflow-only if
preferred. Name a second maintainer to verify during the existing monthly recovery review that the
workflow remains enabled and its last health job is newer than six hours. GitHub directs scheduled
notifications to the schedule owner and automatically disables public-repository schedules after
60 days without repository activity; the
[alert runbook](./docs/runbooks/respond-to-alerts.md#authentication-synthetic-health) contains the
exact verification and re-enable commands.

### Configure and operate protected releases

Use [Deploy and roll back production](./docs/runbooks/deploy-production.md) to create the protected
release input bundle, keep the launch switch off until every prerequisite passes, verify exact
secret versions and image provenance, deploy the reviewed manifest, perform the human-only
Authentication initialization, inspect receipts, and select an exact rollback target. Use
[Configure hosted Plunk SMTP](./docs/runbooks/configure-hosted-smtp.md) first to create the external
paid/no-branding account, authenticate the sending domain, set its independent spend cap, and place
only the SMTP password in Secret Manager. Use
[Recover production into a disposable project](./docs/runbooks/disaster-recovery.md)
only for a declared recovery exercise or incident; it owns temporary recovery authority, exact
backup selection, the lost-write acknowledgement, measured recovery evidence, exact access removal,
and deliberate cleanup of one reviewed disposable project.

Keep `a-novel/agora-infra` active until the complete live acceptance task passes. Its eventual
retirement is a separate administrator action described by
[Archive the legacy infrastructure repository](./docs/runbooks/archive-legacy-infrastructure.md):
the procedure fails closed on an absent or renamed target, requires task #277 to be closed, revokes
legacy authority, disables legacy Actions, retains the interactive GitHub confirmation, and verifies
the exact archived repository afterwards. This repository never performs that action automatically.

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
| `ops/`                                    | Small, tested CI and operator shims shared by the roots.                       |
| `tests/`                                  | Mocked OpenTofu, manifest, Renovate, allowlist, and sanitized plan fixtures.   |
| `docs/architecture.md`                    | Lifecycle, authority, state, delivery, and portability decisions.              |
| `docs/google-cloud.md`                    | Provider resource map, trust boundaries, and official Google Cloud references. |
| `docs/costs/production.md`                | Current unit assumptions and launch/capacity monthly cost ranges.              |
| `docs/runbooks/`                          | Human recovery and deployment procedures with verifiable outcomes.             |

Local modules begin only when two real call sites share a resource shape or one security invariant needs a single implementation. Singleton resources stay in their owning root.

### Plan-output boundary

`ops/plan-summary.sh` reads an OpenTofu JSON plan and emits only counts grouped by action and resource
type. It blocks every deletion, replacement, or state-forget action on a managed resource, including
resource types introduced after the gate was written, and rejects unknown action combinations.
Resource addresses, values, outputs, environment variables, DSNs, and tokens stay out of public
logs.

`ops/tofu-gate.sh` is the only live OpenTofu entry point. It accepts only `bootstrap`, `foundation`,
or `release`; uses the private GCS backend; and keeps provider diagnostics in runner-private files.
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

The production manifest selects the two reviewed `v2.5.1` launch families, but this code alone still
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
