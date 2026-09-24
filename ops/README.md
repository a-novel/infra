# Infrastructure operator commands

This directory has two audiences. Human operators use the small command surface below. GitHub
Actions calls the protected internals directly. Keeping those boundaries separate makes the human
path easy to resume without weakening plan custody, deletion authorization, or secret-safe logs.

This surface follows Google's guidance to [save and approve a plan before apply](https://cloud.google.com/docs/terraform/best-practices/operations)
and to [limit custom provisioning scripts](https://cloud.google.com/docs/terraform/best-practices/general-style-structure).
The commands validate and route operator intent; OpenTofu remains the resource owner. Direct
mutations are limited to prerequisites OpenTofu cannot grant to itself, and each owning runbook
removes that temporary authority.

## Human entry points

| Command                                                    | Purpose                                                                                      | Cloud mutation                                                           |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| [`go run ./cmd/infra verify-env`](../cmd/infra/)           | Validate the operator-selected management and workload project IDs.                          | No                                                                       |
| [`verify-repository-gate.sh`](./verify-repository-gate.sh) | Verify required-check sources, bypass actors, and the release switch.                        | No                                                                       |
| [`bootstrap-plan.sh`](./bootstrap-plan.sh)                 | Create or consume the one local bootstrap plan with commit and checksum custody.             | `apply` only                                                             |
| [`go run ./cmd/infra foundation-setup`](../cmd/infra/)     | Configure, provision, and deprivilege the workload foundation from a fresh shell.            | Only the named `configure`, `grant*`, `revoke*`, and `finish` operations |
| [`foundation-audit.sh`](./foundation-audit.sh)             | Check additive IAM, key, secret, registry, and network boundaries OpenTofu cannot close.     | No                                                                       |
| [`go run ./cmd/infra`](../cmd/infra/)                      | Dispatch one semantic protected plan, apply, deploy, rollback, drift, or recovery operation. | Only inside the selected protected workflow                              |
| [`go run ./cmd/infra database`](../cmd/infra/)             | Inspect the database host, prepare a local EC key, or connect through IAP.                   | OS Login public-key upload during `ssh` and `troubleshoot`               |
| [`add-secret-version.sh`](./add-secret-version.sh)         | Add one Secret Manager version from hidden terminal input without echoing the payload.       | Yes                                                                      |

Run these from the repository root in zsh or Bash; do not source the shell scripts.
The Go commands and shell callers of `verify-env` require the Go version in `go.mod`.
Workflow dispatch also needs Git and an authenticated GitHub CLI. Database access needs Google
Cloud CLI and OpenSSH; `database key` needs only OpenSSH and does not contact Google Cloud.
`go run` builds the current checkout through Go's build cache and returns nonzero on failure;
stop on any nonzero status. The compiled command and shell scripts use these diagnostic codes:
`64` means invalid operator input, `65` means a rejected
repository or identity boundary, `70` means a remote result could not be proven, and `75` means
another production workflow is active. The shell scripts also use `69` for a missing command.

Source the committed non-secret operator defaults once in each shell:

```sh
. ./.envrc
go run ./cmd/infra verify-env
```

Add `--github` after bootstrap or foundation has published coordinates. It compares every published
`GCP_*_PROJECT_ID` with the reviewed selection and fails on a mismatch. Credentials, payloads,
plan IDs, receipts, and one-run incident inputs never belong in `.envrc`.

Commands that grant authority, publish protected configuration, or dispatch a workflow require a
clean local `master` equal to remote `master`. Read-only audits and emergency revocation remain
available without that repository check.

### Database host operations

```text
go run ./cmd/infra database inspect authentication
go run ./cmd/infra database key
go run ./cmd/infra database ssh authentication
go run ./cmd/infra database troubleshoot authentication
go run ./cmd/infra database coordinates
```

`coordinates` prints one JSON object after both service-owned hosts and their disk IDs pass validation.
An error returns nonzero without printing partial coordinates. SSH defaults to a one-hour public-key
registration; use `--ttl <duration>` to select a positive duration in seconds, minutes, hours, or days.

### Protected workflow operations

```text
go run ./cmd/infra drift
go run ./cmd/infra drift assess-pull-request <pull-request-number>
go run ./cmd/infra drift observe-rollout json-keys <release-id> <rollout-id>

go run ./cmd/infra foundation plan <bootstrap|foundation>
go run ./cmd/infra foundation apply <bootstrap|foundation> <plan-id>
go run ./cmd/infra foundation plan <service-foundation|service-release> <json-keys|authentication>
go run ./cmd/infra foundation apply <service-foundation|service-release> <json-keys|authentication> <plan-id>
go run ./cmd/infra foundation promote-images service-release <json-keys|authentication>

go run ./cmd/infra release deploy [--no-wait]
go run ./cmd/infra release rollback <receipt-id>
go run ./cmd/infra release recover-first-launch <failed-run-id>
go run ./cmd/infra release drill-database-isolation <receipt-id> 'DRILL authentication'
go run ./cmd/infra release restore-database-isolation <receipt-id> 'RESTORE authentication'

go run ./cmd/infra recovery plan-workload <replacement-project-id> <receipt-id>
go run ./cmd/infra recovery apply-workload <replacement-project-id> <receipt-id> <plan-id>
go run ./cmd/infra recovery restore-data <replacement-project-id> <receipt-id> <json-attempt> <auth-attempt> <lost-window> <confirmation>
go run ./cmd/infra recovery cleanup-project <replacement-project-id> <receipt-id> <confirmation>
```

A plan ID and a receipt ID both use `run-id-attempt` syntax. Plan/apply remains two explicit
commands: apply queries the selected plan attempt, derives its reviewed commit, and refuses dispatch
unless that commit is the clean local and remote `master`. The private plan itself remains
root-bound, hash-bound, one-use, and valid for 24 hours. Its creation already enforced the
`allow-resource-deletion` decision for that commit.

Service-foundation selection additionally binds the registered project and private backend scope.
It is disabled until separate activation approval; follow the
[service provisioning boundary](../docs/runbooks/provision-service-projects.md#protected-service-foundation-plans).
The separately enabled [image-publication operation](../docs/runbooks/provision-service-projects.md#protected-service-image-publication)
copies only the selected service's verified family. It takes no plan ID and never creates jobs or
deploys services; plan/apply never perform this publication implicitly.

Renovate PRs that only change image tags and digests are assessed automatically after the normal
PR validation jobs pass. Completion of `master` CI also checks open image PRs against the new base.
The workflow reads release-state metadata using protected-master tooling; it never checks out or
executes candidate code. The resulting verdict refreshes both deletion gates automatically.
Deletion labels remain human-only. A failed assessment needs diagnosis and a manual retry; adding a
label cannot replace a missing verdict.

All other changes use the explicit assessment command above. It requires clean local and remote
`master` and resolves the exact current head and base. The protected workflow verifies that the dispatcher is a
human maintainer before any cloud credential exists. Dispatch only after reviewing candidate
OpenTofu code: planning can execute candidate providers and external data sources. The result is a
payload-free verdict artifact; state, variable files, plans, and diagnostics never leave the
protected runner. Reassess after either commit changes. If the verdict requires approval, a human
maintainer must add and retain `allow-resource-deletion` until merge.

Progress and approval URLs go to stderr. Stdout contains only the promised opaque run identifier, so
another program can capture it without parsing logs. None of these commands prints workflow secrets,
OpenTofu values, credentials, or authorization headers.

The separately enabled [rollout observation](../docs/runbooks/observe-rollout.md#observation-only-workflow)
uses read-only credentials and its own concurrency group, so tracking remains available during a
deployment. It reports the exact rollout's verification outcome without submitting or replaying work.
All other infrastructure operations retain their shared execution guard.

The launcher uses GitHub's dispatch response to identify its run and verifies the exact commit before
returning or watching it. If dispatch cannot be confirmed, inspect the repository's Actions page before
retrying: the request may already have created a run. The launcher never resends an uncertain dispatch.

`plan-summary.sh` enforces `lib/plan-policy.jq` during planning and again before saved-plan apply.
Failed or unresolved checks and weakened protections return exit 65, independently of deletion
approval. Exit 3 continues to mean a managed-resource deletion requiring maintainer approval.
See the [pre-merge assessment policy](../README.md#assess-resource-deletion-impact-before-merge)
for protected settings and coverage limits.

The bootstrap state bucket has one narrow policy exception: an in-place update may add a Delete rule
with age 2 days, prefix `services/`, and exactly the suffixes `/plan.tfplan` and `/plan.metadata.json`.
Its project/name and every existing Delete rule must remain unchanged, and all other protections still
apply. [Cloud Storage intersects these conditions](https://docs.cloud.google.com/storage/docs/lifecycle#lifecycle_configuration),
excluding state, locks and configuration. Missing, broader or unknown selectors are rejected.
Bootstrap declares this [native rule](../bootstrap/README.md#plan-artifact-expiration).
Its protected apply and live verification remain separate human-approved operations before the
service-job writer can be activated. Trusted assessments execute policy from `master`.

## Protected workflow internals

Do not call these as ad-hoc operator shortcuts. Their stable paths are part of the reviewed GitHub
Actions security boundary.

Operational jobs build `infra` from the reviewed checkout before
materializing protected inputs or obtaining cloud credentials. The shared build action disables
cache restoration; the resulting binary embeds the unchanged schemas and needs no Node packages.
Cloud-blind gate automation also uses `infra` and the authenticated GitHub CLI: `assess-images
dispatch`, `assess-images verify`, and `refresh-deletion-gates`. It cannot grant deletion approval.
Use `go run ./cmd/infra <command>` for local fixture debugging. Tests are Go plus the remaining
shell integration suite. Node runs third-party Renovate and Prettier only; the repository contains
no authored JavaScript. Install development dependencies with `pnpm install --frozen-lockfile` before
running `a-novel test -y`: the Go suite exercises the pinned Renovate CLI against a local registry.
That lookup checks extraction and update candidates; it does not create PRs or prove minimum group
size enforcement. Separate policy and deployment-time image-family tests cover those boundaries.

| Boundary                            | Scripts                                                                                                                                                                                                                       |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Saved-plan creation and application | `tofu-gate.sh`, `create-reviewed-plan.sh`, `apply-reviewed-plan.sh`, `infra custody plan`, `plan-summary.sh`                                                                                                                  |
| Configuration and receipt custody   | `infra custody config`, `infra custody receipt`, `infra receipt build`, `infra receipt validate`                                                                                                                              |
| Read-only inspection                | `infra inspect drift`, `infra inspect assess`, `infra custody operation inspect` (private inputs, payload-free results)                                                                                                       |
| Deletion authorization              | `infra assess-images`, `infra refresh-deletion-gates`, `resource-deletion-impact.sh`, `resolve-resource-deletion-assessment.sh`, `verify-resource-deletion-gate.sh`, `verify-deletion-label.sh`, `delete-recovery-project.sh` |
| Release compilation and promotion   | `infra compile-release`, `infra validate-images`, `infra preflight images`, `infra promote release`, `infra promote service`, `preflight-release.sh`                                                                          |
| Ordered release execution           | `release-orchestrator.sh`, `google-release-driver.sh`, `infra database-isolation`, `infra database-release`, `await-auth-initialization.sh`                                                                                   |
| Recovery                            | `infra compile-recovery`, `verify-recovery-points.sh`, `infra promote recovery`                                                                                                                                               |
| Health and root validation          | `infra check-health`, `check-root.sh`, `lib/roots.sh`                                                                                                                                                                         |

`infra custody` shares private file handling and official Google storage clients across
configuration, receipts, and plans. It validates downloads before publishing owner-only local files
and uses generation preconditions for immutable uploads. Plans remain commit-bound, time-limited,
and consumed before apply; receipt retries require identical stored bytes. Only a successful empty
inventory returns exit 4; denied or malformed inventories fail closed.

`infra custody plan apply` replaces the apply coordinator shell logic. For the inactive service roots,
it owns [admission through configuration and completion](../docs/service-operations.md#implemented-service-root-apply)
using the existing Storage Go client; the remaining shell entrypoint only forwards legacy callers.
Failures never automatically release a service guard. Legacy configuration/receipt owners are unchanged.

`infra custody operation inspect <state-bucket> <registered-project> [guard-generation]` reads
the interrupted apply's evidence without invoking OpenTofu or changing admission. The protected
registration authorizes the selected scope; exact object generations and hashes bind the report.
Follow the [inspection contract](../docs/service-operations.md#inspect-an-interrupted-apply) for
required inputs, read-only access and the distinction between evidence and permission to retry.

`infra preflight images <compiled-release.json>` verifies all eight legacy source images.
The protected job-bootstrap workflow uses `infra preflight service-images <manifest> <tfvars>`
before cloud authentication and `infra preflight service-secrets <tfvars>` afterwards. Both image
paths share GitHub CLI provenance verification and Google's registry client for tag/digest and
PostgreSQL-major checks. The compiler remains cloud-blind; secret checks read
metadata only. See the [bootstrap boundary](../docs/runbooks/provision-service-projects.md#protected-service-job-bootstrap).

Image promotion uses the same registry client, without a Docker daemon or Buildx:

```text
infra promote release <compiled-release.json> [receipt-run-id]
infra promote recovery <compiled-images.json>
infra promote service <manifest> <selected-service.tfvars.json>
```

The first two replace the former promotion scripts inside their existing protected workflows;
release promotion requires the preceding source-provenance preflight, and recovery requires the
validated receipt-owned inventory. The service command verifies all four source images and their
producer attestations before copying only that family into the configured service project. It is an
explicit artifact write, not a plan, job execution, deployment, or activation approval. The foundation
workflow calls it only for the separately enabled `promote-images service-release` operation, using
authorized native inputs and the existing foundation administrator. Routine publication must use the
separately reviewed service-local publisher, never a PR assessment credential.

Authentication uses Google ADC (including the workflow's existing federation credentials) with
the library's Google CLI fallback and Docker credential helpers. Tags are checked before copying;
denied or ambiguous lookups fail instead of implying absence. Copies preserve the full OCI descriptor
and confirm every destination, including receipt tags. An uncertain upload is read back; failure
leaves existing artifacts intact and requires inspection, not deletion or an automatic command retry.
Registry-enforced immutable tags remain the concurrent-write guard, and retention policy must protect
receipt-referenced images. These commands do not make a multi-image transfer atomic.

`infra database-release` consolidates preparation, bounded restart, restoration, and new-boot
readiness for one service-owned host. Its protected command forms are:

```text
infra database-release current <project> <zone> <service>
infra database-release wait <project> <zone> <service> <revision|none> <previous-status>
infra database-release prepare <project> <zone> <service> <disk-id> <revision> [proof-file] [expected-metadata-sha256]
infra database-release deploy <project> <zone> <service> <disk-id> <revision> <image> <password-version> <backup-password-version>
infra database-release restore <project> <zone> <service> <disk-id> <database-json>
infra database-release recover-first-launch <project> <zone> <service> <disk-id> <failed-revision> <receipt-bucket>
```

`service` is `authentication` or `json-keys`. Deploy prepares a fresh backup boundary unless
`DATABASE_CHANGE_PROOF` selects an exact, unexpired local proof; live metadata and disk identity
are checked before restart. Restore consumes the receipt's database object (`null` means idle).
First-launch recovery only clears the exact failed revision when no service-owned success receipt
exists; it never reruns initialization. The release coordinator owns compensation after failures.

## Change rules

- Add a human command only when it removes substantial repeated or stateful operator logic.
- Derive non-secret repository and cloud coordinates on every invocation.
- Require explicit flags for project IDs, plan/receipt IDs, confirmations, and other real choices.
- Validate all inputs before the first mutation.
- Never source or evaluate generated shell, persist an operator session file, or add a generic prompt
  helper.
- Never read a secret payload for an audit. Secret metadata and IAM are sufficient.
- Keep provider diagnostics and OpenTofu values out of public logs.
- Do not add a task runner or orchestration dependency for this surface.
