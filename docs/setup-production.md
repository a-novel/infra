# Set up production

This is the only ordered first-production procedure. Run it once for a new environment. After it
passes, use the [production operations index](./runbooks/README.md); do not replay setup to deploy,
rotate a secret, restore data, or handle an incident.

## Rules

- A human runs cloud commands from a private, non-recorded zsh session. Agents never run `gcloud`,
  dispatch production workflows, or apply OpenTofu.
- Stop at the first failed check. Resume that step after correction; do not repeat successful
  mutations just to recreate output.
- Keep secret payloads in the approved password manager and Secret Manager only. Never place them
  in `.envrc`, shell variables, command arguments, GitHub, OpenTofu, logs, or chat.
- Keep `PRODUCTION_RELEASES_ENABLED=false` until step 6.

## Start or resume

Create the ignored operator file and set the two project IDs before step 1:

```sh
if [ ! -e .envrc ]; then
  cp .envrc.example .envrc
fi
chmod 600 .envrc
${EDITOR:-vi} .envrc
. ./.envrc
./ops/verify-operator-env.sh
```

Use the globally unique management and workload project IDs chosen for this environment. Leave the
four SMTP placeholders until step 4; their authoritative sources are listed there. Credentials and
payloads never belong in this file.

Before every resumed step:

```sh
. ./.envrc
./ops/verify-operator-env.sh --github
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

| Step | Procedure                                                                                                                                                                                                | PASS condition                                                                                                                                          |
| ---: | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
|    0 | Run [Start or resume](#start-or-resume).                                                                                                                                                                 | Clean current `master`; repository gate passes.                                                                                                         |
|    1 | [Bootstrap the management plane](./runbooks/bootstrap-management-plane.md).                                                                                                                              | State, WIF, protected environments, secret containers, and audit controls pass; temporary bootstrap authority is removed.                               |
|    2 | [Provision the workload foundation](./runbooks/provision-workload-foundation.md).                                                                                                                        | The workload project and both protected roots converge; the final audit passes; temporary access is removed.                                            |
|    3 | [Inspect the PostgreSQL host](./runbooks/operate-postgresql-host.md#select-the-exact-host) through [foundation verification](./runbooks/operate-postgresql-host.md#verify-foundation-state-after-apply). | One private VM and preserved disk exist; no external IP or running database container exists.                                                           |
|    4 | [Configure and persist hosted SMTP](#4-configure-and-persist-the-smtp-contract).                                                                                                                         | The provider account, cost cap, privacy settings, domain, DKIM, SPF, DMARC, and non-secret contract pass.                                               |
|    5 | [Create the initial payload versions](#5-create-the-initial-payload-versions).                                                                                                                           | All seven live containers have one selected enabled numeric version; no payload was printed.                                                            |
|    6 | [Activate production](#6-activate-production).                                                                                                                                                           | The reviewed release succeeds, the initializer is deleted, traffic is healthy, recovery jobs pass, rotation is scheduled, and the receipt is immutable. |
|    7 | [Lock backup retention](#7-lock-backup-retention).                                                                                                                                                       | The seven-day bucket retention policy is irreversibly locked through reviewed code.                                                                     |
|    8 | [Verify alert delivery](./runbooks/respond-to-alerts.md#verify-channels-without-adding-machinery).                                                                                                       | Both channels and all policies have owners and deliver tests.                                                                                           |
|    9 | [Run the clean-room recovery drill](./runbooks/disaster-recovery.md).                                                                                                                                    | A private replacement passes RPO/RTO and health; temporary access and project are removed.                                                              |
|   10 | [Archive the legacy repository](./runbooks/archive-legacy-infrastructure.md).                                                                                                                            | Legacy credentials and Actions are disabled, work is drained, and only `a-novel/agora-infra` is archived.                                               |

Do not advance on a partial PASS. Record successful workflow URLs and private acceptance evidence.

## 4. Configure and persist the SMTP contract

Follow the [hosted SMTP procedure](./runbooks/configure-hosted-smtp.md). It identifies four
long-lived non-secret values; put their actual values in `.envrc`:

| Variable            | Value                                                              |
| ------------------- | ------------------------------------------------------------------ |
| `SMTP_HOST`         | The hostname in Plunk's SMTP `host` field, without scheme or port. |
| `SMTP_USERNAME`     | Plunk's SMTP `username` field, not the secret key.                 |
| `SMTP_SENDER_EMAIL` | The organization-controlled sender address on the verified domain. |
| `SMTP_SENDER_NAME`  | The display name recipients should see.                            |

`SMTP_DKIM_CNAME_RECORDS` is needed only while verifying DNS, so set it in that runbook's shell,
not in `.envrc`. The Plunk `sk_` secret key is the SMTP password and remains in the password
manager until step 5.

## 5. Create the initial payload versions

The foundation created empty Secret Manager containers. Prepare these values in the approved
password manager; do not export them:

| Secret                                               | Initial value                                                             |
| ---------------------------------------------------- | ------------------------------------------------------------------------- |
| `production-authentication-postgres-password`        | A random 64-character value using only `A-Z`, `a-z`, `0-9`, `_`, and `-`. |
| `production-authentication-postgres-backup-password` | A different random value with the same contract.                          |
| `production-json-keys-postgres-password`             | A third different random value with the same contract.                    |
| `production-json-keys-postgres-backup-password`      | A fourth different random value with the same contract.                   |
| `production-authentication-smtp-sender-password`     | The exact Plunk `sk_` secret key, not its `pk_` public key.               |
| `production-authentication-super-admin-password`     | A separate random 64-character password-manager value.                    |
| `production-json-keys-app-master-key`                | Exactly 64 hexadecimal characters representing 32 random bytes.           |

Generate passwords with the password manager's cryptographic generator. Compare the four database
passwords there and confirm they are all distinct. Do not generate or assemble a payload in the
shell. Host, port, user, database, and TLS mode are derived from reviewed infrastructure; only the
password is secret. The private VPC protects the non-TLS database path. A hybrid, external, or
differently trusted network requires a reviewed PostgreSQL TLS design first.

Create the seven immutable versions in dependency order. The script prompts twice with terminal echo
disabled and prints only safe IDs and numeric versions:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
./ops/add-secret-version.sh \
  production-authentication-postgres-password \
  production-authentication-postgres-backup-password \
  production-json-keys-postgres-password \
  production-json-keys-postgres-backup-password \
  production-authentication-smtp-sender-password \
  production-authentication-super-admin-password \
  production-json-keys-app-master-key
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected: seven `Created <secret> version <number>` lines. If it stops partway, list version metadata
and rerun only the remaining IDs. Never create duplicates to reproduce terminal output and never use
the mutable `latest` alias.

## 6. Activate production

Use [Deploy and roll back production](./runbooks/deploy-production.md) sections 1–4 to verify the
boundary, select the seven numeric versions, and store `RELEASE_CONFIG_JSON`. Then prepare one pull
request that fills both complete image families in `deploy/production/images.yaml` with stable
SemVer tags and exact `sha256:` digests. Both database images must use PostgreSQL 18.

During this setup-only use, the release switch remains `false`, and no prior release receipt, clean
restore, or backup-monitor result exists. The fresh scheduled snapshot and first-release
compensation contract replace those steady-state deployment preconditions until the initial release
succeeds. All other deployment preconditions still apply.

The first release may compensate by deleting everything it created. Before merging its exact pull
request, derive the current branch's PR and add the deletion gate:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
REPOSITORY='a-novel/infra'
ACTIVATION_PR="$(gh pr view --repo "$REPOSITORY" --json number --jq .number)"
[[ "$ACTIVATION_PR" =~ ^[1-9][0-9]*$ ]]
gh pr edit "$ACTIVATION_PR" --repo "$REPOSITORY" --add-label allow-resource-deletion
gh pr view "$ACTIVATION_PR" --repo "$REPOSITORY" --json labels,reviewDecision,statusCheckRollup --jq '{labels:[.labels[].name],reviewDecision,checks:[.statusCheckRollup[] | {name,status,conclusion}]}'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Merge only after review and required checks pass. Pull that merge to local `master`, then enable the
one-time launch switch:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
REPOSITORY='a-novel/infra'
git switch master
git pull --ff-only
test -z "$(git status --porcelain)"
test "$(gh variable get PRODUCTION_RELEASES_ENABLED --repo "$REPOSITORY")" = false
printf 'Type enable-production-releases to authorize launch: '
IFS= read -r RELEASE_CONFIRMATION
test "$RELEASE_CONFIRMATION" = enable-production-releases
gh variable set PRODUCTION_RELEASES_ENABLED --repo "$REPOSITORY" --body true
unset RELEASE_CONFIRMATION
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Verify the mutation separately:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
test "$(gh variable get PRODUCTION_RELEASES_ENABLED --repo a-novel/infra)" = true
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Wait for a `READY` `agora-data` scheduled snapshot no older than six hours. Then start the release
without blocking the shell; the workflow pauses for the human-only initializer:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
RELEASE_RUN_ID="$(./ops/run-workflow.sh release deploy --no-wait)"
printf 'Release run ID: %s\n' "$RELEASE_RUN_ID"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Open the printed workflow URL. Continue only when it reports that migrations passed and it is waiting
for Authentication initialization.

### Run the human-only Authentication initializer

Collect every coordinate from live state and the reviewed manifest. This block extracts the digest;
do not paste or edit one:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
REPOSITORY='a-novel/infra'
MANAGEMENT_PROJECT_ID="$INFRA_MANAGEMENT_PROJECT_ID"
WORKLOAD_PROJECT_ID="$INFRA_WORKLOAD_PROJECT_ID"
DATABASE_ZONE="$(gcloud compute instance-groups managed list --project="$WORKLOAD_PROJECT_ID" --filter='name=agora-database' --format='value(zone.basename())')"
[[ "$DATABASE_ZONE" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]]
REGION="${DATABASE_ZONE%-*}"
DATABASE_INSTANCE_URI="$(gcloud compute instance-groups managed list-instances agora-database --project="$WORKLOAD_PROJECT_ID" --zone="$DATABASE_ZONE" --format='value(instance)' --limit=1)"
DATABASE_INSTANCE_NAME="${DATABASE_INSTANCE_URI##*/}"
DATABASE_PRIVATE_IP="$(gcloud compute instances describe "$DATABASE_INSTANCE_NAME" --project="$WORKLOAD_PROJECT_ID" --zone="$DATABASE_ZONE" --format='value(networkInterfaces[0].networkIP)')"
[[ "$DATABASE_PRIVATE_IP" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]
AUTH_SUPER_ADMIN_EMAIL="$(gcloud config get-value account 2>/dev/null)"
MANAGEMENT_PROJECT_NUMBER="$(gcloud projects describe "$MANAGEMENT_PROJECT_ID" --format='value(projectNumber)')"
WORKLOAD_PROJECT_NUMBER="$(gcloud projects describe "$WORKLOAD_PROJECT_ID" --format='value(projectNumber)')"
INVOCATION_TAG_KEY="$(gcloud resource-manager tags keys list --parent="projects/${WORKLOAD_PROJECT_NUMBER}" --filter='shortName=agora-invocation' --format='value(name)')"
INITIALIZER_TAG_VALUE="$(gcloud resource-manager tags values list --parent="$INVOCATION_TAG_KEY" --filter='shortName=initializer' --format='value(name)')"
sole_enabled_secret_version() {
  gcloud secrets versions list "$1" --project="$MANAGEMENT_PROJECT_ID" --format=json \
    | jq --raw-output '
        map(select(.state == "ENABLED"))
        | if length == 1 then .[0].name | split("/") | last
          else error("expected exactly one enabled secret version")
          end
      '
}
AUTH_POSTGRES_PASSWORD_VERSION="$(sole_enabled_secret_version production-authentication-postgres-password)"
AUTH_SUPER_ADMIN_PASSWORD_VERSION="$(sole_enabled_secret_version production-authentication-super-admin-password)"
unset -f sole_enabled_secret_version
INIT_DIGEST="$(node --input-type=module -e 'import { readFile } from "node:fs/promises"; import { parse } from "yaml"; const manifest = parse(await readFile("deploy/production/images.yaml", "utf8")); process.stdout.write(manifest.components["service-authentication"].images["jobs/init"].digest);')"
[[ "$MANAGEMENT_PROJECT_NUMBER" =~ ^[0-9]+$ ]]
[[ "$INITIALIZER_TAG_VALUE" =~ ^tagValues/[0-9]+$ ]]
[[ "$AUTH_POSTGRES_PASSWORD_VERSION" =~ ^[1-9][0-9]*$ ]]
[[ "$AUTH_SUPER_ADMIN_PASSWORD_VERSION" =~ ^[1-9][0-9]*$ ]]
[[ "$INIT_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]]
INIT_IMAGE="${REGION}-docker.pkg.dev/${WORKLOAD_PROJECT_ID}/agora-production/service-authentication/jobs/init@${INIT_DIGEST}"
INIT_SERVICE_ACCOUNT="agora-auth-initializer@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com"
INIT_JOB_PARENT="//run.googleapis.com/projects/${WORKLOAD_PROJECT_ID}/locations/${REGION}/jobs/agora-authentication-init"
gcloud artifacts docker images describe "$INIT_IMAGE" --project="$WORKLOAD_PROJECT_ID" --format='none'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Select the sole active release for the current `master` commit:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
RELEASE_RUNS="$(gh run list --repo "$REPOSITORY" --workflow release.yaml --branch master --status in_progress --limit 10 --json databaseId,headSha,status,url)"
test "$(jq 'length' <<<"$RELEASE_RUNS")" -eq 1
test "$(jq --raw-output '.[0].headSha' <<<"$RELEASE_RUNS")" = "$(git rev-parse HEAD)"
RELEASE_RUN_ID="$(jq --raw-output '.[0].databaseId' <<<"$RELEASE_RUNS")"
[[ "$RELEASE_RUN_ID" =~ ^[1-9][0-9]*$ ]]
unset RELEASE_RUNS
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Immediately before creating the initializer, prove it is absent:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
if gcloud run jobs describe agora-authentication-init --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --format='none' 2>/dev/null; then
  printf 'STOP: the one-time initializer already exists; use the recovery rules below.\n' >&2
  return 1
fi
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Create the inert job without environment variables, secrets, commands, arguments, or an execution:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud run jobs deploy agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" \
  --image="$INIT_IMAGE" --service-account="$INIT_SERVICE_ACCOUNT" \
  --tasks=1 --parallelism=1 --max-retries=1 --task-timeout=300s \
  --cpu=1 --memory=512Mi \
  --network=agora-production --subnet="agora-production-${REGION}" \
  --network-tags=agora-authentication --vpc-egress=all-traffic \
  --labels=environment=production,managed-by=human-initializer,component=authentication,role=init
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Verify the definition separately:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud run jobs describe agora-authentication-init --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --format=export
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected: the exact digest, service account, one task, and private network; no `env`, secret
annotation, command, or arguments.

Attach the human-only tag before adding bootstrap configuration and prove it is the sole direct tag:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud resource-manager tags bindings create --tag-value="$INITIALIZER_TAG_VALUE" --parent="$INIT_JOB_PARENT" --location="$REGION"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Verify the sole direct tag separately:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud resource-manager tags bindings list --parent="$INIT_JOB_PARENT" --location="$REGION" --format=json |
  jq --exit-status --arg expected "$INITIALIZER_TAG_VALUE" '([.[].tagValue] | sort) == ([$expected] | sort)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected: `true`. The job must not carry `release`, `scheduled`, `internal`, or `recovery`.
Only now attach the exact email and secret versions; this update must not execute the job:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud run jobs update agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" \
  --image="$INIT_IMAGE" --service-account="$INIT_SERVICE_ACCOUNT" \
  --tasks=1 --parallelism=1 --max-retries=1 --task-timeout=300s \
  --cpu=1 --memory=512Mi \
  --network=agora-production --subnet="agora-production-${REGION}" \
  --network-tags=agora-authentication --vpc-egress=all-traffic \
  --set-env-vars="SUPER_ADMIN_EMAIL=${AUTH_SUPER_ADMIN_EMAIL},POSTGRES_HOST=${DATABASE_PRIVATE_IP},POSTGRES_PORT=5433,POSTGRES_USER=agora_authentication,POSTGRES_DATABASE=agora_authentication,POSTGRES_TLS_ENABLED=false" \
  --set-secrets="POSTGRES_PASSWORD=projects/${MANAGEMENT_PROJECT_NUMBER}/secrets/production-authentication-postgres-password:${AUTH_POSTGRES_PASSWORD_VERSION},SUPER_ADMIN_PASSWORD=projects/${MANAGEMENT_PROJECT_NUMBER}/secrets/production-authentication-super-admin-password:${AUTH_SUPER_ADMIN_PASSWORD_VERSION}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Verify the tag again in a separate block:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud resource-manager tags bindings list --parent="$INIT_JOB_PARENT" --location="$REGION" --format=json |
  jq --exit-status --arg expected "$INITIALIZER_TAG_VALUE" '([.[].tagValue] | sort) == ([$expected] | sort)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected: the update finishes without an execution and the tag check remains `true`. Execute the
job exactly once with no overrides:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud run jobs execute agora-authentication-init --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --wait
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Wait for the already-running release separately:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gh run watch "$RELEASE_RUN_ID" --repo "$REPOSITORY" --exit-status
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

The workflow accepts only a successful execution created after its prompt and writes the create-only
`production/initialization/complete.json` marker. After the release succeeds, delete the dormant
privileged job while its initializer tag is still attached:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud run jobs delete agora-authentication-init --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --quiet
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Verify deletion separately:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
if gcloud run jobs describe agora-authentication-init --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --format='none' 2>/dev/null; then
  printf 'STOP: the initializer still exists; keep its initializer tag and investigate.\n' >&2
  return 1
fi
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Never detach or replace the initializer tag before deletion. Verify the release with
[deployment section 7](./runbooks/deploy-production.md#7-verify-deployment-and-rotation), then
complete [SMTP delivery validation](./runbooks/configure-hosted-smtp.md#5-validate-without-exposing-the-credential).

### Recover a partial initializer setup

- If the release compensates before the initializer exists, create nothing. Correct the workflow
  failure and dispatch a fresh release.
- If an inert untagged job exists, verify its exported definition contains no environment or secrets.
  Attach only the initializer tag and continue only while a fresh release is waiting. Delete it and
  restart if the invariant is uncertain.
- If an untagged initializer contains bootstrap configuration, freeze production writers and treat
  it as an IAM incident. Preserve audit evidence, delete the job, and review its creators before
  retrying.
- If an initializer-tagged job remains after compensation, keep the tag attached. Delete it before a
  fresh dispatch, or execute it without overrides only after that fresh workflow reaches its prompt.
- If deletion fails after success, leave the initializer tag attached and resolve the control-plane
  error before the next release.

Never create the initialization marker manually.

### Prove initial database recovery

The first empty host has no source database to dump. The release still must validate a fresh
foundation snapshot, activate both clusters together, run migrations, create both logical backups,
restore both into clean clusters, and run the backup monitor before traffic.

Verify the private receipt records all five recovery execution names. Record the completion times,
image digests, and two selected manifest attempt IDs privately. If any check fails, keep writers
disabled and correct the declared image, secret, IAM, network, or schema contract in code.

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
RETENTION_PLAN_ID="$(./ops/run-workflow.sh foundation plan bootstrap)"
printf 'Retention plan ID: %s\n' "$RETENTION_PLAN_ID"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Review that exact plan, then apply only its printed ID:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
[[ "$RETENTION_PLAN_ID" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]]
./ops/run-workflow.sh foundation apply bootstrap "$RETENTION_PLAN_ID"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

If the shell was restarted, copy the non-secret plan ID printed by the successful plan into
`RETENTION_PLAN_ID` before applying it. Finally, verify:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
MANAGEMENT_PROJECT_ID="$INFRA_MANAGEMENT_PROJECT_ID"
MANAGEMENT_PROJECT_NUMBER="$(gcloud projects describe "$MANAGEMENT_PROJECT_ID" --format='value(projectNumber)')"
BACKUP_BUCKET="${MANAGEMENT_PROJECT_ID}-${MANAGEMENT_PROJECT_NUMBER}-backups"
gcloud storage buckets describe "gs://${BACKUP_BUCKET}" --format='yaml(name,retention_policy,soft_delete_policy,lifecycle_config)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected: retention remains 604800 seconds, `isLocked` is `true`, soft-delete retention is zero,
and lifecycle age is 14 days. Never use a direct bucket-lock command; the irreversible state and
review evidence belong in Git.

## Resume map

| Existing evidence                                                     | Resume at                                                              |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Management bootstrap audit passes and temporary authority is removed. | Step 2.                                                                |
| Foundation final audit passes and temporary access is removed.        | Step 3.                                                                |
| Idle private host and disk pass inspection.                           | Step 4.                                                                |
| SMTP domain and contract pass; no secret versions exist.              | Step 5.                                                                |
| All seven numeric versions exist; no release configuration exists.    | Step 6, deploy sections 1–4.                                           |
| Release is waiting for initialization.                                | [Run the initializer](#run-the-human-only-authentication-initializer). |
| Release receipt and recovery evidence pass; retention is unlocked.    | Step 7.                                                                |
| Retention, alerts, and clean-room drill pass.                         | Step 10.                                                               |

A successful workflow is evidence; do not rerun it merely to reproduce terminal output.
