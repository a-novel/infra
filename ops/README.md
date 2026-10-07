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

| Command                                                    | Purpose                                                                                  | Cloud mutation                                                           |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| [`go run ./cmd/infra verify-env`](../cmd/infra/)           | Validate the operator-selected management and workload project IDs.                      | No                                                                       |
| [`verify-repository-gate.sh`](./verify-repository-gate.sh) | Verify required-check sources, bypass actors, and the release switch.                    | No                                                                       |
| [`bootstrap-plan.sh`](./bootstrap-plan.sh)                 | Create or consume the one local bootstrap plan with commit and checksum custody.         | `apply` only                                                             |
| [`go run ./cmd/infra foundation-setup`](../cmd/infra/)     | Configure, provision, and deprivilege the workload foundation from a fresh shell.        | Only the named `configure`, `grant*`, `revoke*`, and `finish` operations |
| [`foundation-audit.sh`](./foundation-audit.sh)             | Check additive IAM, key, secret, registry, and network boundaries OpenTofu cannot close. | No                                                                       |
| [`go run ./cmd/infra`](../cmd/infra/)                      | Dispatch one semantic protected plan, apply, drift, or recovery operation.               | Only inside the selected protected workflow                              |
| [`go run ./cmd/infra database`](../cmd/infra/)             | Inspect the database host, prepare a local EC key, or connect through IAP.               | OS Login public-key upload during `ssh` and `troubleshoot`               |
| [`add-secret-version.sh`](./add-secret-version.sh)         | Add one Secret Manager version from hidden terminal input without echoing the payload.   | Yes                                                                      |

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
go run ./cmd/infra drift inspect-operation <json-keys|authentication> [guard-generation]

go run ./cmd/infra foundation plan <bootstrap|foundation>
go run ./cmd/infra foundation apply <bootstrap|foundation> <plan-id>
go run ./cmd/infra foundation plan <service-foundation|service-release> <json-keys|authentication>
go run ./cmd/infra foundation apply <service-foundation|service-release> <json-keys|authentication> <plan-id>
go run ./cmd/infra foundation promote-images service-release <json-keys|authentication>
go run ./cmd/infra foundation finish-operation <service> <guard-generation> 'FINISH <service> <guard-generation>'


go run ./cmd/infra recovery plan-native <registered-destination>
go run ./cmd/infra recovery apply-native <registered-destination> <plan-id>
go run ./cmd/infra recovery restore-native <registered-destination> <preparation-generation> 'RESTORE-SQL <registered-destination> <preparation-generation>'
go run ./cmd/infra recovery cleanup-native <registered-destination> 'DELETE <registered-destination>'
```

A plan ID and a receipt ID both use `run-id-attempt` syntax. Plan/apply remains two explicit
commands: apply queries the selected plan attempt, derives its reviewed commit, and refuses dispatch
unless that commit is the clean local and remote `master`. The private plan itself remains
root-bound, hash-bound, one-use, and valid for 24 hours. Its creation already enforced the
`allow-resource-deletion` decision for that commit.

Native API releases select an explicit trust zone in `foundation.yaml`; follow the
[native release procedure](../docs/runbooks/submit-release.md). The service-only helper above uses
`zone=none` and must not be used for the registered zone-specific configurations.

Service-foundation selection additionally binds the registered project and private backend scope.
It is disabled until separate activation approval; follow the
[service provisioning boundary](../docs/runbooks/provision-service-projects.md#protected-service-foundation-plans).
The separately enabled [image-publication operation](../docs/runbooks/provision-service-projects.md#protected-service-image-publication)
copies only the selected service's verified family. It takes no plan ID and never creates jobs or
deploys services; plan/apply never perform this publication implicitly.

Renovate PRs that only change image versions are assessed automatically after the normal
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

[Interrupted-apply inspection](../docs/service-operations.md#inspect-an-interrupted-apply) likewise uses
read-only credentials and separate concurrency, with protected foundation registration and environment
review. A successful inspection is not a successful deployment or permission to unlock/retry.
The separately enabled [finish operation](../docs/service-operations.md#finish-an-already-recorded-operation)
can remove only the exact live guard of a recorded converged apply after
its original workflow attempt completes. It never repeats deployment or repairs missing evidence,
and uses writer concurrency.
All other infrastructure operations retain their shared execution guard.

The launcher uses GitHub's dispatch response to identify its run and verifies the exact commit before
watching it to successful completion. If dispatch cannot be confirmed, inspect the repository's Actions page before
retrying: the request may already have created a run. The launcher never resends an uncertain dispatch.

`plan-summary.sh` enforces `lib/plan-policy.jq` during planning and again before saved-plan apply.
Failed or unresolved checks and weakened protections return exit 65, independently of deletion
approval. Exit 3 continues to mean a managed-resource deletion requiring maintainer approval.
See the [pre-merge assessment policy](../README.md#assess-resource-deletion-impact-before-merge)
for protected settings and coverage limits.

The bootstrap state bucket has one narrow policy exception: an in-place update may add one Delete rule
with age 2 days and exactly the suffixes `/plan.tfplan` and `/plan.metadata.json`. Its prefixes must be
`services/` alone, the exact pair `workloads/production/private/` and `workloads/production/public/`,
or `workloads/production/public-api/` alone.
Its project/name and every existing Delete rule must remain unchanged, and all other protections still
apply. [Cloud Storage intersects these conditions](https://docs.cloud.google.com/storage/docs/lifecycle#lifecycle_configuration),
excluding state, locks and configuration. Missing, broader or unknown selectors are rejected.
Bootstrap declares [separate native rules](../bootstrap/README.md#plan-artifact-expiration) for the
dedicated-service, private/public and public-api prefixes. Protected apply and live verification remain
separate human-approved operations before the service-job writer can be activated. Trusted assessments
execute policy from `master`.

## Protected workflow internals

Do not call these as ad-hoc operator shortcuts. Their stable paths are part of the reviewed GitHub
Actions security boundary.

Operational jobs build `infra` from the reviewed checkout before
materializing protected inputs or obtaining cloud credentials. The shared build action disables
cache restoration; the resulting binary embeds the unchanged schemas and needs no Node packages.
Cloud-blind gate automation also uses `infra` and the authenticated GitHub CLI: `assess-updates
dispatch`, `assess-images verify`, `assess-versions verify`, and `refresh-deletion-gates`. It cannot
grant deletion approval.
Use `go run ./cmd/infra <command>` for local fixture debugging. Tests are Go plus the remaining
shell integration suite. Node runs third-party Renovate and Prettier only; the repository contains
no authored JavaScript. Install development dependencies with `pnpm install --frozen-lockfile` before
running `a-novel test -y`: the Go suite exercises the pinned Renovate CLI against a local registry.
That lookup checks extraction and update candidates; it does not create PRs or prove minimum group
size enforcement. Separate policy and deployment-time image-family tests cover those boundaries.

| Boundary                            | Scripts                                                                                                                                                                                                                                          |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Saved-plan creation and application | `tofu-gate.sh`, `create-reviewed-plan.sh`, `infra custody plan`, `plan-summary.sh`                                                                                                                                                               |
| Configuration and receipt custody   | `infra custody config`, `infra custody receipt`, `infra receipt validate`                                                                                                                                                                        |
| Read-only inspection                | `infra inspect drift`, `infra inspect assess`, `infra custody operation inspect` (private inputs, payload-free results)                                                                                                                          |
| Deletion authorization              | `infra assess-updates`, `infra assess-images`, `infra assess-versions`, `infra refresh-deletion-gates`, `resource-deletion-impact.sh`, `resolve-resource-deletion-assessment.sh`, `verify-resource-deletion-gate.sh`, `verify-deletion-label.sh` |
| Image validation and promotion      | `infra validate-images`, `infra preflight service-images`, `infra promote service`                                                                                                                                                               |
| Retained database operations        | `infra database-release`, `await-auth-initialization.sh`                                                                                                                                                                                         |
| Recovery                            | `infra custody recovery execute`, `infra custody recovery cleanup`                                                                                                                                                                               |
| Health and root validation          | `infra check-health`, `check-root.sh`, `lib/roots.sh`                                                                                                                                                                                            |

`infra custody` shares private file handling and official Google storage clients across
configuration, receipts, and plans. It validates downloads before publishing owner-only local files
and uses generation preconditions for immutable uploads. Plans remain commit-bound, time-limited,
and consumed before apply; receipt retries require identical stored bytes. Only a successful empty
inventory returns exit 4; denied or malformed inventories fail closed.

`infra custody plan apply` replaces the apply coordinator shell logic. For the inactive service roots,
it owns [admission through configuration and completion](../docs/service-operations.md#implemented-service-root-apply)
using the existing Storage Go client; the remaining shell entrypoint only forwards legacy callers.
Failures never automatically release a service guard. Legacy configuration/receipt owners are unchanged.

`infra custody operation finish <state-bucket> <registered-project> <guard-generation> <confirmation>`
is the protected workflow's narrow cleanup counterpart. It requires explicit recovery activation,
master workflow identity, exact completion/configuration evidence and a completed original run attempt;
only a generation-conditioned live guard deletion is allowed. It is not an ad-hoc unlock shortcut.

`infra custody operation inspect <state-bucket> <registered-project> [guard-generation]` reads
the interrupted operation's evidence without invoking OpenTofu or changing admission. The protected
registration authorizes the selected scope; exact object generations and hashes bind the report.
Follow the [inspection contract](../docs/service-operations.md#inspect-an-interrupted-apply) for
required inputs, read-only access and the distinction between evidence and permission to retry.

Image preflight validates the selected native service family and verifies its producer attestations
before any image copy. Secret preflight reads only the selected numeric versions' metadata:

```text
infra preflight service-images <manifest> <selected-service.tfvars.json>
infra preflight service-secrets <selected-service.tfvars.json>
infra promote service <manifest> <selected-service.tfvars.json>
```

Promotion preserves OCI digests, verifies immutable destination tags, and stops after an
unconfirmed copy. It grants no deployment or execution approval. The protected foundation
workflow permits it only through the separately enabled service image-promotion operation.

`infra preflight resolve-images <manifest> <output.json>` resolves and verifies a complete
version-only manifest into a private digest snapshot when required by tooling. Historical
receipts remain readable through custody and `infra receipt validate`; they cannot drive
the retired deployment compiler, promotion or rollback commands.

`infra database-release current` and `wait` inspect host readiness. Its
`maintenance-plan`, `maintenance-replace` and `maintenance-recover` operations are internal
steps of the protected foundation workflow, not standalone operator mutation commands.
See [database maintenance](../docs/runbooks/operate-postgresql-host.md#protected-database-maintenance)
for the exact native backup/SQL proof, preservation rules and interrupted-operation handling.

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
