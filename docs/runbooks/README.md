# Production runbooks

This is the only first-production-run index. Start at step 0, finish each `Pass` check, then move to
the named next step. Open one runbook at a time; no operator needs to remember the whole system.

## Rules to keep in mind

1. Run local operator blocks directly in the existing configured zsh session. Each block scopes its
   fail-fast options, preserves the terminal on failure, and prints `STOP`. Blocks explicitly marked
   for a remote COS host use that host's Bash session. Keep tracing disabled and never paste
   unfiltered output into GitHub, chat, or a shared terminal.
2. Agents never run `gcloud` or `tofu apply`. A named human runs those commands only where a runbook
   explicitly authorizes them.
3. A branch or pull request can validate and preview only. Cloud changes run from reviewed `master`
   behind the documented GitHub environment.
4. The first management-plane apply is the only local apply. Every later apply consumes a saved,
   reviewed plan through a protected workflow.
5. Keep `PRODUCTION_RELEASES_ENABLED=false` until step 6 tells you to change it.
6. Every linked runbook starts with an **Operator context** block. Paste it once before its steps,
   including when resuming in the middle.

Google Cloud concepts and provider behavior are linked from the runbook that uses them. Repository-
specific decisions, stop conditions, commands, expected results, and recovery actions remain here.

`ops/run-workflow.sh` is the only manual-dispatch helper used below. It accepts only the four
production workflow files, pins dispatch to a clean local `master` that equals remote `master`,
refuses to queue behind any active run in their shared concurrency group, identifies only the new
run created by its dispatch, and waits for success by default. Progress and the approval URL go to
stderr; its stdout is only the requested `run-id` or `run-id-attempt`. Chained plan/apply commands set
`EXPECTED_SHA` so a new merge stops the sequence before another dispatch. The first release uses
`--no-wait` only so its run ID remains in the operator shell while the human initializer proceeds
from the printed run URL.

## Resume an interrupted first run

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gh variable get PRODUCTION_RELEASES_ENABLED --repo a-novel/infra
gh run list --repo a-novel/infra --branch master --limit 20 \
  --json databaseId,workflowName,displayTitle,headSha,status,conclusion,createdAt,url
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Find the last completed `Pass` in this index. Resume at the next step or use the active runbook's
partial-failure section. Do not repeat a mutating command only because the local terminal closed.

## First production run

### 0. Inspect the repository gate

Run from the infrastructure repository root:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
git switch master
git pull --ff-only
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Check the local checkout once:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
git branch --show-current
git status --short
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Look for: the branch is `master`, the pull succeeds, and `git status` prints nothing. Check this once
before starting the first run.

Then inspect the GitHub gate:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
./ops/verify-repository-gate.sh
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Look for: GitHub authentication names the intended account; ruleset enforcement is `active`; the
required checks are exactly `epic-freeze`, `lint-repository`, `merge-gate`, `scan-infrastructure`,
and `validate-opentofu`; and the release-switch result is either `[]` before bootstrap or one
`PRODUCTION_RELEASES_ENABLED` entry whose value is `false`. Stop if the command fails or any result
differs.

`Next`: step 1.

### 1. Bootstrap the management plane

Run [Bootstrap and verify the management plane](./bootstrap-management-plane.md) from Operator
context through step 13. This is the only procedure that authorizes a local `tofu apply`, and only
after its explicit human authorization gate passes.

Use this metadata-only check when the runbook is complete:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
REPOSITORY='a-novel/infra'
test "$(gh variable get PRODUCTION_RELEASES_ENABLED --repo "$REPOSITORY")" = false

gh variable list --repo "$REPOSITORY"
for environment in production-foundation production-release production-recovery; do
  gh variable list --repo "$REPOSITORY" --env "$environment"
  gh secret list --repo "$REPOSITORY" --env "$environment"
done
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

`Pass`: remote state, plan custody, four WIF providers, exact IAM, three protected environments,
secret containers, recovery storage, and audit evidence all pass the runbook; temporary bootstrap
authority is removed; the release switch remains false.

`Next`: step 2.

### 2. Provision the workload foundation

Run [Provision and verify the workload foundation](./provision-workload-foundation.md) from Operator
context through step 8. Use only the protected `foundation.yaml` plan/apply sequence. Do not run a
local foundation apply.

After its final cleanup, rerun the zero-key and no-public-path checks from sections 6 and 7, then:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
REPOSITORY='a-novel/infra'
test "$(gh variable get PRODUCTION_RELEASES_ENABLED --repo "$REPOSITORY")" = false
gh run list --repo "$REPOSITORY" --workflow foundation.yaml --branch master --limit 10 \
  --json databaseId,displayTitle,headSha,status,conclusion,url
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

`Pass`: one private workload project exists; the post-apply plan is empty; temporary project,
parent, billing, and primitive IAM are removed; the private network, idle PostgreSQL host, immutable
registry, budgets, quotas, alerts, logging, and runtime identities match the runbook.

`Next`: step 3.

### 3. Verify the idle PostgreSQL host

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
test "$(gh variable get PRODUCTION_RELEASES_ENABLED --repo a-novel/infra)" = false
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Run these sections of [Operate the private PostgreSQL host](./operate-postgresql-host.md), in order:

1. [Operator context](./operate-postgresql-host.md#operator-context).
2. [Select the exact host](./operate-postgresql-host.md#select-the-exact-host).
3. [Verify foundation state after apply](./operate-postgresql-host.md#verify-foundation-state-after-apply).
4. [Inspect the host through IAP](./operate-postgresql-host.md#inspect-the-host-through-iap), using
   only the disabled-manifest commands.

`Pass`: exactly one stateful VM has one private address and the preserved disk; it has no external
IP; the expected firewall and snapshot policy exist; no PostgreSQL container is running yet.

`Next`: step 4. Leave the host idle.

### 4. Configure hosted SMTP

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
test "$(gh variable get PRODUCTION_RELEASES_ENABLED --repo a-novel/infra)" = false
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Run [Configure hosted Plunk SMTP](./configure-hosted-smtp.md) from Operator context through step 4.
Do not run its delivery, bounce, or cap tests yet; those require the released Authentication
service.

`Pass`: the organization owns one paid no-branding Plunk project and its recovery access; spending
is capped; tracking is disabled; the sending domain is verified; the exact STARTTLS-on-587 contract
is recorded privately; only the SMTP password payload is ready to enter Secret Manager.

`Next`: step 5.

### 5. Populate the nine secret versions

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
test "$(gh variable get PRODUCTION_RELEASES_ENABLED --repo a-novel/infra)" = false
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Prepare the four database passwords and construct both DSNs privately from the step-3 private
address. Paste the Operator context, then run the single initial-population command in
[Add or rotate a secret version](./secret-versions.md). Never use `latest`.

List metadata after all nine versions are added:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
MANAGEMENT_PROJECT_ID="$(gh variable get GCP_MANAGEMENT_PROJECT_ID --repo a-novel/infra)"
[[ "$MANAGEMENT_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]

for secret in \
  production-authentication-postgres-dsn \
  production-authentication-postgres-password \
  production-authentication-postgres-backup-password \
  production-authentication-smtp-sender-password \
  production-authentication-super-admin-password \
  production-json-keys-app-master-key \
  production-json-keys-postgres-dsn \
  production-json-keys-postgres-password \
  production-json-keys-postgres-backup-password; do
  gcloud secrets versions list "$secret" \
    --project="$MANAGEMENT_PROJECT_ID" \
    --filter='state=ENABLED' \
    --format='table(name.basename(),state,createTime)'
done
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

`Pass`: every secret has one selected enabled numeric version, all four database passwords are
distinct, both DSNs use the exact private address and matching port, and the version IDs are stored
in the private deployment record without payloads.

`Next`: step 6.

### 6. Launch JSON Keys and Authentication

Run [Deploy and roll back production](./deploy-production.md) from Operator context through step 7.
The sequence inside that runbook is authoritative:

1. store the protected non-payload release configuration;
2. merge one complete, attested, digest-pinned image-family update with the required first-launch
   deletion label;
3. wait for the fresh scheduled disk snapshot;
4. deliberately enable the release switch;
5. dispatch the first protected release;
6. let the release activate both databases, migrate, back up, clean-restore, and verify them;
7. run the human-only Authentication initializer once, then delete its job;
8. let the release move JSON Keys, then Authentication, to 100% traffic;
9. verify the hourly JSON Keys rotation schedule and immutable receipt;
10. complete Plunk's bounded delivery, bounce, cap, and log-leak tests.

Use the runbook's exact workflow helper. Do not start a second run while the first is waiting for the
initializer.

`Pass`: the release workflow succeeds at the exact reviewed `master` SHA; a private success receipt
exists; the initializer job is absent; JSON Keys is private and callable only by Authentication;
Authentication is healthy at its public HTTPS edge; both first backups and both clean restores
succeeded; key rotation is scheduled hourly.

`Next`: step 7. If launch fails, use the runbook's compensation or exact-receipt rollback path and
keep normal production writes disabled.

### 7. Lock backup retention after recovery proof

Run [Back up and restore PostgreSQL](./backup-and-restore-postgresql.md), starting with Operator
context and then
[Select and verify the deployed boundary](./backup-and-restore-postgresql.md#select-and-verify-the-deployed-boundary).
Confirm the first-release execution IDs and results. Do not rerun successful jobs merely to produce
duplicate evidence. Follow
[Lock retention after proof](./backup-and-restore-postgresql.md#lock-retention-after-proof).

`Pass`: both logical backups are newer than six hours, both clean restores meet the 90-minute RTO,
the hourly monitor succeeds, daily snapshots exist, the seven-day bucket retention policy is
irreversibly locked through a reviewed code change, and the private recovery record is complete.

`Next`: step 8.

### 8. Verify alert ownership and delivery

Run [Respond to production alerts](./respond-to-alerts.md) from Operator context once as an
acceptance check. In particular, verify the policy inventory, both existing Google email channels,
the scheduled GitHub health owner, and one successful health run newer than six hours.

`Pass`: eight Google policies are enabled, both existing notification channels are enabled and
verified, the current schedule owner has GitHub Actions failure notifications enabled, a second
maintainer is named, and no duplicate pager, webhook, metric, or test resource was added.

`Next`: step 9.

### 9. Prove clean-room recovery

Run [Recover production into a disposable project](./disaster-recovery.md) from Operator context as
a drill. Execute all steps, including cross-project access removal, the deletion-gated cleanup pull
request, project deletion, and delayed cost recording.

`Pass`: the selected backups restore in a new private project; both services pass private health;
measured RPO is no more than six hours and RTO no more than 90 minutes; temporary access is removed;
the project reaches `DELETE_REQUESTED`; the recovery receipt and measured cost are recorded
privately.

`Next`: step 10.

### 10. Archive the legacy repository

Run [Archive the legacy infrastructure repository](./archive-legacy-infrastructure.md) from Operator
context only after the complete replacement acceptance record is closed. Keep the command's
interactive confirmation.

`Pass`: legacy external credentials are revoked, legacy Actions is disabled, open work is drained,
exactly `a-novel/agora-infra` is archived, and `a-novel/infra` remains active.

The first production run is complete.

## Routine and incident entry points

Do not restart at step 0 for routine work. Use the owning procedure directly:

| Need                                                               | Runbook                                                                |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------- |
| Deploy or roll back an application version                         | [Deploy and roll back production](./deploy-production.md)              |
| Scale, resize, inspect, or roll back the database host             | [Operate the private PostgreSQL host](./operate-postgresql-host.md)    |
| Back up, restore, or prove the pre-change recovery gate            | [Back up and restore PostgreSQL](./backup-and-restore-postgresql.md)   |
| Add, rotate, disable, or schedule destruction of a payload version | [Add or rotate a secret version](./secret-versions.md)                 |
| Diagnose an alert or failed scheduled check                        | [Respond to production alerts](./respond-to-alerts.md)                 |
| Rebuild after the workload project is no longer trusted            | [Recover production into a disposable project](./disaster-recovery.md) |
| Recover a corrupt or incorrect OpenTofu state object               | [Recover a prior state generation](./state-recovery.md)                |

State recovery is never a normal deployment step. Application rollback uses an immutable release
receipt; data recovery uses logical backups; clean-room recovery uses a new project.
