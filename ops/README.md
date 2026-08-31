# Infrastructure operator commands

This directory has two audiences. Human operators use the small command surface below. GitHub
Actions calls the protected internals directly. Keeping those boundaries separate makes the human
path easy to resume without weakening plan custody, deletion authorization, or secret-safe logs.

This surface follows Google's guidance to [save and approve a plan before apply](https://cloud.google.com/docs/terraform/best-practices/operations)
and to [limit custom provisioning scripts](https://cloud.google.com/docs/terraform/best-practices/general-style-structure).
The scripts validate and route operator intent; OpenTofu remains the resource owner. Direct
mutations are limited to prerequisites OpenTofu cannot grant to itself, and each owning runbook
removes that temporary authority.

## Human entry points

| Command                                                    | Purpose                                                                                      | Cloud mutation                                                           |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| [`verify-operator-env.sh`](./verify-operator-env.sh)       | Validate the operator-selected management and workload project IDs.                          | No                                                                       |
| [`verify-repository-gate.sh`](./verify-repository-gate.sh) | Verify rulesets, required checks, environments, labels, and the disabled release switch.     | No                                                                       |
| [`bootstrap-plan.sh`](./bootstrap-plan.sh)                 | Create or consume the one local bootstrap plan with commit and checksum custody.             | `apply` only                                                             |
| [`foundation.sh`](./foundation.sh)                         | Configure, provision, and deprivilege the workload foundation from a fresh shell.            | Only the named `configure`, `grant*`, `revoke*`, and `finish` operations |
| [`foundation-audit.sh`](./foundation-audit.sh)             | Check additive IAM, key, secret, registry, and network boundaries OpenTofu cannot close.     | No                                                                       |
| [`run-workflow.sh`](./run-workflow.sh)                     | Dispatch one semantic protected plan, apply, deploy, rollback, drift, or recovery operation. | Only inside the selected protected workflow                              |
| [`database-host.sh`](./database-host.sh)                   | Inspect the database host, register an OS Login key, or connect through IAP.                 | OS Login public-key registration only                                    |
| [`add-secret-version.sh`](./add-secret-version.sh)         | Add one Secret Manager version from hidden terminal input without echoing the payload.       | Yes                                                                      |

Run these from the repository root. They use Bash internally and work from an existing zsh or Bash
session; do not source them. Exit code `64` means invalid operator input, `65` means a rejected
repository or identity boundary, `69` means a missing command, `70` means a remote result could
not be proven, and `75` means another production workflow is active.

Source the committed non-secret operator defaults once in each shell:

```sh
. ./.envrc
./ops/verify-operator-env.sh
```

Add `--github` after bootstrap or foundation has published coordinates. It compares every published
`GCP_*_PROJECT_ID` with the reviewed selection and fails on a mismatch. Credentials, payloads,
plan IDs, receipts, and one-run incident inputs never belong in `.envrc`.

Commands that grant authority, publish protected configuration, or dispatch a workflow require a
clean local `master` equal to remote `master`. Read-only audits and emergency revocation remain
available without that repository check.

### Database host operations

```text
./ops/database-host.sh inspect
./ops/database-host.sh key
./ops/database-host.sh ssh
./ops/database-host.sh troubleshoot
```

### Protected workflow operations

```text
./ops/run-workflow.sh drift

./ops/run-workflow.sh foundation plan <bootstrap|foundation>
./ops/run-workflow.sh foundation apply <bootstrap|foundation> <plan-id>

./ops/run-workflow.sh release deploy [--no-wait]
./ops/run-workflow.sh release rollback <receipt-id>

./ops/run-workflow.sh recovery plan-workload <replacement-project-id> <receipt-id>
./ops/run-workflow.sh recovery apply-workload <replacement-project-id> <receipt-id> <plan-id>
./ops/run-workflow.sh recovery restore-data <replacement-project-id> <receipt-id> <json-attempt> <auth-attempt> <lost-window> <confirmation>
./ops/run-workflow.sh recovery cleanup-project <replacement-project-id> <receipt-id> <confirmation>
```

A plan ID and a receipt ID both use `run-id-attempt` syntax. Plan/apply remains two explicit
commands: apply queries the selected plan attempt, derives its reviewed commit, and refuses dispatch
unless that commit is the clean local and remote `master`. The private plan itself remains
root-bound, hash-bound, one-use, and valid for 24 hours. Its creation already enforced the
`allow-resource-deletion` decision for that commit.

Progress and approval URLs go to stderr. Stdout contains only the promised opaque run identifier, so
another program can capture it without parsing logs. None of these commands prints workflow secrets,
OpenTofu values, credentials, or authorization headers.

## Protected workflow internals

Do not call these as ad-hoc operator shortcuts. Their stable paths are part of the reviewed GitHub
Actions security boundary.

| Boundary                            | Scripts                                                                                                                                                                          |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Saved-plan creation and application | `tofu-gate.sh`, `create-reviewed-plan.sh`, `apply-reviewed-plan.sh`, `plan-custody.sh`, `plan-summary.sh`                                                                        |
| Configuration and receipt custody   | `config-custody.sh`, `receipt-custody.sh`, `build-receipt.mjs`, `validate-receipt.mjs`                                                                                           |
| Deletion authorization              | `verify-deletion-label.sh`, `delete-recovery-project.sh`                                                                                                                         |
| Release compilation and promotion   | `compile-release.mjs`, `validate-image-update.mjs`, `verify-release-images.sh`, `promote-release-images.sh`, `preflight-release.sh`                                              |
| Ordered release execution           | `release-orchestrator.sh`, `google-release-driver.sh`, `prepare-database-change.sh`, `deploy-database-release.sh`, `restore-database-release.sh`, `await-auth-initialization.sh` |
| Recovery                            | `compile-recovery.mjs`, `verify-recovery-points.sh`, `promote-recovery-images.sh`                                                                                                |
| Health and root validation          | `check-authentication-health.sh`, `check-root.sh`, `lib/roots.sh`                                                                                                                |

These scripts stay single-purpose because their inputs, permissions, and diagnostics differ. A lower
file count would not justify coupling state access, deployment authority, and recovery authority.

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
