# Set up production

This guide covers management and foundation setup. First application activation requires a separately
reviewed plan; the routine release workflow assumes initialized databases. For an existing environment, use the [production operations index](./runbooks/README.md); do not replay setup to deploy,
rotate a secret, restore data, or handle an incident.

## Rules

- A human runs cloud commands from a private, non-recorded zsh session. Agents never run `gcloud`,
  dispatch production workflows, or apply OpenTofu.
- Stop at the first failed check. Resume that step after correction; do not repeat successful
  mutations just to recreate output.
- Keep secret payloads in the approved password manager and Secret Manager only. Never place them
  in `.envrc`, shell variables, command arguments, GitHub, OpenTofu, logs, or chat.
- Keep `PRODUCTION_RELEASES_ENABLED=false`; routine APIs use the protected foundation workflow.
- Project-scoped `gcloud` commands must select the project explicitly from `.envrc`; never rely on
  the active CLI project. Project/IAM operations and `gs://` operations already name their exact
  resource. Global login/discovery commands and the public `cos-cloud` image catalog are exceptions;
  disaster recovery uses its explicitly selected source or replacement project.

## Start or resume

The [operator command reference](../ops/README.md) lists prerequisites, including the Go version
in `go.mod` for protected workflow commands.

Review the committed non-secret production defaults, then load them:

```sh
. ./.envrc
go run ./cmd/infra verify-env
```

For another environment, update `.envrc` through a pull request before step 1. It contains only
stable IDs, placement, human principals, alert recipients, SMTP metadata, and `PLATFORM_AUTH_URL`.
That URL is the public web client's HTTPS origin (no path or trailing slash), from its hosting
configuration; the reviewed production value is `https://www.agorastoryverse.com`. Credentials and
payloads never belong there. With `direnv`, run `direnv allow` after reviewing a change.

Before every resumed step:

```sh
. ./.envrc
go run ./cmd/infra verify-env --github
git switch master
git pull --ff-only
git status --short
./ops/verify-repository-gate.sh
```

Expected: current clean `master`, matching published coordinates, and a passing repository gate.
Inspect recent runs before dispatching anything:

```sh
gh run list --repo a-novel/infra --branch master --limit 20 --json databaseId,workflowName,headSha,status,conclusion,createdAt,url
```

## Setup sequence

| Step | Procedure                                                                                          | PASS condition                                                                                                                                          |
| ---: | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
|    0 | Run [Start or resume](#start-or-resume).                                                           | Clean current `master`; repository gate passes.                                                                                                         |
|    1 | [Bootstrap the management plane](./runbooks/bootstrap-management-plane.md).                        | State, WIF, protected environments, secret containers, and audit controls pass; temporary bootstrap authority is removed.                               |
|    2 | [Provision the workload foundation](./runbooks/provision-workload-foundation.md).                  | The workload project and both protected roots converge; the final audit passes; temporary access is removed.                                            |
|    3 | [Inspect the PostgreSQL hosts and prepare OS Login](./runbooks/debug-postgresql-host.md).          | Each database has its own private VM and preserved SSD disk; the local EC key is ready; bounded IAP logins succeed; no public path exists.              |
|    4 | [Configure and persist hosted SMTP](#4-configure-and-persist-the-smtp-contract).                   | The Workspace relay, app password, domain, DKIM, SPF, DMARC, and non-secret contract pass.                                                              |
|    5 | [Create the initial payload versions](#5-create-the-initial-payload-versions).                     | All six application containers have one selected enabled numeric version; no payload was printed.                                                       |
|    6 | [Activate production](#6-activate-production).                                                     | The reviewed release succeeds, the initializer is deleted, traffic is healthy, recovery jobs pass, rotation is scheduled, and the receipt is immutable. |
|    7 | [Lock backup retention](#7-lock-backup-retention).                                                 | The seven-day bucket retention policy is irreversibly locked through reviewed code.                                                                     |
|    8 | [Verify alert delivery](./runbooks/respond-to-alerts.md#verify-channels-without-adding-machinery). | Both channels and all policies have owners and deliver tests.                                                                                           |
|    9 | [Run the clean-room recovery drill](./runbooks/disaster-recovery.md).                              | A private replacement passes RPO/RTO and health; temporary access and project are removed.                                                              |
|   10 | [Archive the legacy repository](./runbooks/archive-legacy-infrastructure.md).                      | Legacy credentials and Actions are disabled, work is drained, and only `a-novel/agora-infra` is archived.                                               |

Do not advance on a partial PASS. Record successful workflow URLs and private acceptance evidence.

## 4. Configure and persist the SMTP contract

Follow the [hosted SMTP procedure](./runbooks/configure-hosted-smtp.md). It verifies the four
long-lived non-secret values committed in `.envrc`:

| Variable            | Value                                                              |
| ------------------- | ------------------------------------------------------------------ |
| `SMTP_HOST`         | `smtp-relay.gmail.com`, without scheme or port.                    |
| `SMTP_USERNAME`     | The existing Workspace account that owns the app password.         |
| `SMTP_SENDER_EMAIL` | The organization-controlled sender address on the verified domain. |
| `SMTP_SENDER_NAME`  | The display name recipients should see.                            |

`SMTP_DKIM_SELECTOR` is a one-run DNS input and stays in that runbook's shell. The Google app
password remains in the password manager until step 5.

## 5. Create the initial payload versions

The foundation created empty Secret Manager containers. Prepare these values in the approved
password manager; do not export them:

| Secret                                           | Initial value                                                                                            |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| `production-authentication-postgres-password`    | A random 64-character value using only `A-Z`, `a-z`, `0-9`, `_`, and `-`.                                |
| `production-json-keys-postgres-password`         | A different random value with the same contract.                                                         |
| `production-authentication-smtp-sender-password` | The Google app password belonging to `SMTP_USERNAME`.                                                    |
| `production-authentication-super-admin-password` | A separate random 64-character password-manager value.                                                   |
| `production-authentication-waitlist-secret`      | The invitation-list signing key, at least 32 characters, shared with the production Apps Script project. |
| `production-json-keys-app-master-key`            | Exactly 64 hexadecimal characters representing 32 random bytes.                                          |

Generate passwords with the password manager's cryptographic generator. Compare the two database
passwords there and confirm they are distinct. Do not generate or assemble a payload in the
shell. Host, port, user, database, and TLS mode are derived from reviewed infrastructure; only the
password is secret. The private VPC protects the non-TLS database path. A hybrid, external, or
differently trusted network requires a reviewed PostgreSQL TLS design first.

Create the six immutable application versions in dependency order. Native-backup TLS enrollment uses
the separate [certificate procedure](./runbooks/backup-and-restore-postgresql.md). The script reads each value twice with
terminal echo disabled and prints only safe IDs and numeric versions:

```sh
./ops/add-secret-version.sh \
  production-authentication-postgres-password \
  production-json-keys-postgres-password \
  production-authentication-smtp-sender-password \
  production-authentication-super-admin-password \
  production-authentication-waitlist-secret \
  production-json-keys-app-master-key
```

Expected: six `Created <secret> version <number>` lines. If it stops partway, list version metadata
and rerun only the remaining IDs. Never create duplicates to reproduce terminal output and never use
the mutable `latest` alias.

## 6. Activate production

Existing initialized environments use [Release APIs with OpenTofu](./runbooks/submit-release.md).
Publish the selected service/zone inputs, review the private plan, check the candidate, then promote
traffic with a separate reviewed plan. Image-manifest merges do not deploy automatically.

For a fresh environment or replacement data disk, stop before the routine release path. Review
database startup, schema migration, initial signing-key creation and human-only Authentication
initialization as one explicit activation plan. Verify its resource allocation and cost first.
The removed shared-host rebuild and automatic first-launch compensation are not activation paths.

### Run the human-only Authentication initializer

Initialization remains a human-only operation on an uninitialized Authentication database.
The reviewed activation plan must bind the current data-disk identity, exact image and numeric
secret versions, initializer-only identity/tag and one successful execution without overrides.
Verify that the initial account exists, preserve private completion evidence and delete the dormant
initializer while its tag remains attached. Routine releases must never invoke it.

### Recover a partial initializer setup

Preserve the disk and any completion evidence. Inspect the exact execution before deciding whether
initialization ran; a lost workflow or missing response is not permission to repeat it. Keep the
initializer tag attached during cleanup. A configured untagged initializer requires an IAM incident
review before resuming. Never manufacture an initialization marker.

### Prove initial database recovery

Before accepting activation, create backups and restore both databases into clean targets.
Keep the verified image digests, disk identities, backup attempt IDs and completion evidence
privately. Preserve working backup schedules throughout a native pgBackRest transition; follow
[backup acceptance](./runbooks/accept-native-backups.md) before retiring them.

## 7. Lock backup retention

Locking a Cloud Storage retention policy is irreversible: it cannot be removed or shortened. Do this
only after both initial clean restores and their private recovery record pass.

1. Open a dedicated pull request changing only
   `google_storage_bucket.backups.retention_policy.is_locked` in `bootstrap/storage.tf` from
   `false` to `true`.
2. Confirm the sanitized plan changes one bucket in place with no replacement or deletion.
3. Merge after review, then refresh clean `master`:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
git switch master
git pull --ff-only
test -z "$(git status --porcelain)"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Create the protected bootstrap plan in a separate block:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
RETENTION_PLAN_ID="$(go run ./cmd/infra foundation plan bootstrap)"
printf 'Retention plan ID: %s\n' "$RETENTION_PLAN_ID"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Review that exact plan, then apply only its printed ID:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
[[ "$RETENTION_PLAN_ID" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]]
go run ./cmd/infra foundation apply bootstrap "$RETENTION_PLAN_ID"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

If the shell was restarted, copy the non-secret plan ID printed by the successful plan into
`RETENTION_PLAN_ID` before applying it. Finally, verify:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
MANAGEMENT_PROJECT_ID="$INFRA_MANAGEMENT_PROJECT_ID"
MANAGEMENT_PROJECT_NUMBER="$(gcloud projects describe "$INFRA_MANAGEMENT_PROJECT_ID" --format='value(projectNumber)')"
BACKUP_BUCKET="${MANAGEMENT_PROJECT_ID}-${MANAGEMENT_PROJECT_NUMBER}-backups"
gcloud storage buckets describe "gs://${BACKUP_BUCKET}" --format='yaml(name,retention_policy,soft_delete_policy,lifecycle_config)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected: retention remains 604800 seconds, `isLocked` is `true`, soft-delete retention is zero,
and lifecycle age is 14 days. Never use a direct bucket-lock command; the irreversible state and
review evidence belong in Git.

## Resume map

| Existing evidence                                                            | Resume at                                                              |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Management bootstrap audit passes and temporary authority is removed.        | Step 2.                                                                |
| Foundation final audit passes and temporary access is removed.               | Step 3.                                                                |
| Both idle private database hosts and SSD disks pass inspection.              | Step 4.                                                                |
| SMTP domain and contract pass; no secret versions exist.                     | Step 5.                                                                |
| All six application numeric versions exist; no release configuration exists. | Step 6, explicit activation review.                                    |
| Fresh activation requires initialization.                                    | [Run the initializer](#run-the-human-only-authentication-initializer). |
| Release receipt and recovery evidence pass; retention is unlocked.           | Step 7.                                                                |
| Retention, alerts, and clean-room drill pass.                                | Step 10.                                                               |

A successful workflow is evidence; do not rerun it merely to reproduce terminal output.
