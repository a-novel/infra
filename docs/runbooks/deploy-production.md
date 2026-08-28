# Deploy and roll back production

> First production run: step 6. This procedure activates databases, proves backups and restores,
> initializes Authentication once, and moves service traffic in the fixed order.

Use this runbook for a reviewed release of JSON Keys and Authentication, or to restore the whole
application to one exact prior successful receipt. A protected merge that changes the production
manifest starts deployment only after the documented repository launch switch is true. The first
post-bootstrap release, an explicit retry, and rollback use manual dispatch. A branch or pull
request never receives Google credentials.

Official references: [Cloud Run revisions](https://cloud.google.com/run/docs/managing/revisions),
[traffic migration and rollback](https://cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration),
[executing Cloud Run jobs](https://cloud.google.com/run/docs/execute/jobs),
[deploying Cloud Run jobs](https://cloud.google.com/sdk/gcloud/reference/run/jobs/deploy),
[tagging Cloud Run jobs](https://cloud.google.com/run/docs/configuring/jobs/tags),
[Cloud Run job secrets](https://cloud.google.com/run/docs/configuring/jobs/secrets),
[Artifact Registry image copying](https://cloud.google.com/artifact-registry/docs/docker/copy-images),
[Secret Manager version states](https://cloud.google.com/secret-manager/docs/managing-secret-versions),
and [GitHub artifact attestations](https://docs.github.com/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).

## Operator context

Run this and later blocks in the existing configured zsh session. Complete the four hosted-SMTP
values, then paste this block once before section 1:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
umask 077

REPOSITORY='a-novel/infra'
REGION='europe-west1'
DATABASE_ZONE='europe-west1-b'

MANAGEMENT_PROJECT_ID="$(gh variable get GCP_MANAGEMENT_PROJECT_ID --repo "$REPOSITORY")"
WORKLOAD_PROJECT_ID="$(gh variable get GCP_WORKLOAD_PROJECT_ID --repo "$REPOSITORY")"
BACKUP_BUCKET_NAME="$(gh variable get GCP_BACKUP_BUCKET --repo "$REPOSITORY")"
RECEIPT_BUCKET_NAME="$(gh variable get GCP_RECEIPT_BUCKET --repo "$REPOSITORY")"

AUTH_SUPER_ADMIN_EMAIL="$(gcloud config get-value account 2>/dev/null)"
SMTP_HOST=''
SMTP_USERNAME=''
SMTP_SENDER_EMAIL=''
SMTP_SENDER_NAME=''
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

## Guarantees and deliberate limits

One globally serialized workflow performs this fixed graph:

1. verify all eight GHCR images, exact digests, producer attestations, family SemVer, and PostgreSQL
   major before obtaining Google credentials;
2. verify nine numeric secret versions, four fully granted quota preferences, a recent scheduled
   disk snapshot, and fresh logical backups for both databases;
3. copy the exact digests into regional Artifact Registry and verify the destination digests;
4. restart the stateful PostgreSQL host with receipt-bound images and secret versions;
5. pause all periodic release schedulers and create both service candidates at zero traffic;
6. execute JSON Keys migrations, JSON Keys rotation, then Authentication migrations;
7. execute both logical backups, restore both into clean disposable clusters, and run the backup
   monitor;
8. on first launch only, wait for the exact human-run Authentication initializer and record it;
9. verify the private JSON Keys revision is Ready and move it to 100%;
10. call Authentication's candidate `/v2/healthcheck`, which probes its database, SMTP, and the newly
    active private JSON Keys gRPC dependency, then move Authentication to 100%;
11. converge OpenTofu, resume periodic schedulers, and publish an immutable private receipt.

After the database rollout begins, any failure follows one compensation edge to the preceding receipt.
It restores prior traffic, images, secret-version references, and database container metadata.
Migrations and row data are intentionally not reversed because migrations must remain backward
compatible. Data restore belongs to the backup or disaster-recovery runbook.

The Authentication initializer is never managed by the release root. Only configured human `user:`
or `group:` principals receive its tag, dedicated service identity, narrow deployer role, registry
read, and conditional invocation. Release, recovery, and scheduler identities cannot attach that
identity or tag, change Cloud Run IAM, execute it, or use execution overrides. JSON Keys rotation is
automated separately: release runs it once after migration, then Cloud Scheduler evaluates the
idempotent job at minute 10 every hour.

## Preconditions and stop conditions

- Bootstrap and foundation have converged through their protected workflows.
- For an existing deployment, the latest scheduled clean-restore drills and backup monitor are
  healthy. First activation proves both new backups and both clean restores inside this release
  before initialization or traffic.
- Every application secret has an enabled numeric version created through
  [Add or rotate a secret version](./secret-versions.md).
- Each source image has a GitHub producer attestation signed by that service's `release.yaml` from
  `master` on a GitHub-hosted runner, plus a stable complete SemVer tag.
- `production-release` accepts only protected branches and contains only its release WIF coordinates
  plus `RELEASE_CONFIG_JSON`.
- The repository variable `PRODUCTION_RELEASES_ENABLED` is `false` during initial setup and `true`
  only after every prerequisite in this runbook passes.
- The exact `master` manifest is the reviewed desired state.
- The live PostgreSQL release metadata still matches the newest immutable receipt; the private
  preflight hash fails closed on drift or a missing receipt.
- For the first application release only, a maintainer added `allow-resource-deletion` before the
  release PR merged. First-launch compensation must be authorized to remove a partially created
  application and return to the empty receipt.

Stop if a workflow requests a service-account key, prints a plan/configuration value, asks to invoke
the initializer with an override, or shows a deletion whose merge did not carry
`allow-resource-deletion`.

## 1. Verify the repository and release environment

Run in a private terminal with tracing disabled:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
git switch master
git pull --ff-only
test -z "$(git status --porcelain)"
MASTER_SHA="$(git rev-parse HEAD)"
test "$MASTER_SHA" = "$(gh api "repos/${REPOSITORY}/commits/master" --jq .sha)"

gh api "repos/${REPOSITORY}/environments/production-release" \
  --jq '{name,deployment_branch_policy,protection_rules}'
RELEASES_ENABLED="$(gh variable get PRODUCTION_RELEASES_ENABLED --repo "$REPOSITORY")"
[[ "$RELEASES_ENABLED" == false || "$RELEASES_ENABLED" == true ]]
printf 'Production release launch switch: %s\n' "$RELEASES_ENABLED"
gh variable list --repo "$REPOSITORY" --env production-release
gh secret list --repo "$REPOSITORY" --env production-release
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: protected branches, no custom branch policy, exactly
`GCP_RELEASE_WORKLOAD_IDENTITY_PROVIDER` and `GCP_RELEASE_SERVICE_ACCOUNT`, and—after section 4—only
`RELEASE_CONFIG_JSON`. The launch switch must still be `false` during first-time setup. Routine
release has no second approval queue because workflow code and the manifest already passed the
protected pull-request merge gate.

Create the deletion label if absent:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gh label create allow-resource-deletion \
  --repo "$REPOSITORY" \
  --color B60205 \
  --description 'Explicit maintainer approval for managed-resource deletion at merge' \
  --force
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

The gate replays the PR timeline. It accepts the label only when a maintainer with write, maintain,
or admin permission added it and it remained present when that exact PR merged. A post-merge label
does not authorize deletion.

## 2. Collect foundation-owned coordinates

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
[[ "$MANAGEMENT_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "$WORKLOAD_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "$MANAGEMENT_PROJECT_ID" != "$WORKLOAD_PROJECT_ID" ]]

[[ "$BACKUP_BUCKET_NAME" == "${MANAGEMENT_PROJECT_ID}-"*'-backups' ]]
[[ "$RECEIPT_BUCKET_NAME" == "${MANAGEMENT_PROJECT_ID}-"*'-deployment-receipts' ]]

DATABASE_INSTANCE_URI="$(gcloud compute instance-groups managed list-instances agora-database \
  --project="$WORKLOAD_PROJECT_ID" --zone="$DATABASE_ZONE" \
  --format='value(instance)' --limit=1)"
DATABASE_INSTANCE_NAME="${DATABASE_INSTANCE_URI##*/}"
[[ "$DATABASE_INSTANCE_NAME" == agora-database-* ]]
DATABASE_PRIVATE_IP="$(gcloud compute instances describe "$DATABASE_INSTANCE_NAME" \
  --project="$WORKLOAD_PROJECT_ID" --zone="$DATABASE_ZONE" \
  --format='value(networkInterfaces[0].networkIP)')"
[[ "$DATABASE_PRIVATE_IP" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]

NETWORK_ID="projects/${WORKLOAD_PROJECT_ID}/global/networks/agora-production"
SUBNET_ID="projects/${WORKLOAD_PROJECT_ID}/regions/${REGION}/subnetworks/agora-production-${REGION}"
gcloud compute networks describe agora-production \
  --project="$WORKLOAD_PROJECT_ID" --format='yaml(name,autoCreateSubnetworks,routingConfig.routingMode)'
gcloud compute networks subnets describe "agora-production-${REGION}" \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" \
  --format='yaml(name,network,ipCidrRange,privateIpGoogleAccess)'

WORKLOAD_PROJECT_NUMBER="$(gcloud projects describe "$WORKLOAD_PROJECT_ID" \
  --format='value(projectNumber)')"
INVOCATION_TAG_KEY="$(gcloud resource-manager tags keys list \
  --parent="projects/${WORKLOAD_PROJECT_NUMBER}" \
  --filter='shortName=agora-invocation' --format='value(name)')"
[[ "$INVOCATION_TAG_KEY" =~ ^tagKeys/[0-9]+$ ]]

tag_value_id() {
  gcloud resource-manager tags values list --parent="$INVOCATION_TAG_KEY" \
    --filter="shortName=$1" --format='value(name)'
}

INITIALIZER_TAG_VALUE="$(tag_value_id initializer)"
INTERNAL_TAG_VALUE="$(tag_value_id internal)"
RECOVERY_TAG_VALUE="$(tag_value_id recovery)"
RELEASE_TAG_VALUE="$(tag_value_id release)"
SCHEDULED_TAG_VALUE="$(tag_value_id scheduled)"
for value in "$INITIALIZER_TAG_VALUE" "$INTERNAL_TAG_VALUE" "$RECOVERY_TAG_VALUE" \
  "$RELEASE_TAG_VALUE" "$SCHEDULED_TAG_VALUE"; do
  [[ "$value" =~ ^tagValues/[0-9]+$ ]]
done
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: one `agora-database-*` member with an RFC 1918 address, one custom-mode
network, one `10.20.0.0/24` subnet with Private Google Access, and one permanent ID for each of the
five invocation classes. Do not print instance metadata or OpenTofu outputs; either can include
release configuration.

## 3. Select and verify exact secret versions

Use the sole enabled version automatically. During a rotation, the command lists enabled metadata
and asks which numeric version to deploy. It never retrieves payloads.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
select_secret_version() {
  local secret_id="$1"
  local enabled_versions version_count selected_version

  enabled_versions="$(gcloud secrets versions list "$secret_id" \
    --project="$MANAGEMENT_PROJECT_ID" --filter='state=ENABLED' \
    --format='value(name.basename())')"
  version_count="$(printf '%s\n' "$enabled_versions" | grep -c . || true)"

  case "$version_count" in
    0) printf 'No enabled version exists for %s.\n' "$secret_id" >&2; return 1 ;;
    1) selected_version="$enabled_versions" ;;
    *)
      gcloud secrets versions list "$secret_id" \
        --project="$MANAGEMENT_PROJECT_ID" --filter='state=ENABLED' \
        --format='table(name.basename(),state,createTime)' >&2
      printf 'Enabled numeric version for %s: ' "$secret_id" >&2
      IFS= read -r selected_version
      ;;
  esac

  [[ "$selected_version" =~ ^[1-9][0-9]*$ ]]
  test "$(gcloud secrets versions describe "$selected_version" --secret="$secret_id" \
    --project="$MANAGEMENT_PROJECT_ID" --format='value(state)')" = ENABLED
  printf '%s' "$selected_version"
}

AUTH_POSTGRES_PASSWORD_VERSION="$(select_secret_version production-authentication-postgres-password)"
AUTH_POSTGRES_BACKUP_PASSWORD_VERSION="$(select_secret_version production-authentication-postgres-backup-password)"
AUTH_POSTGRES_DSN_VERSION="$(select_secret_version production-authentication-postgres-dsn)"
AUTH_SMTP_PASSWORD_VERSION="$(select_secret_version production-authentication-smtp-sender-password)"
AUTH_SUPER_ADMIN_PASSWORD_VERSION="$(select_secret_version production-authentication-super-admin-password)"
JSON_POSTGRES_PASSWORD_VERSION="$(select_secret_version production-json-keys-postgres-password)"
JSON_POSTGRES_BACKUP_PASSWORD_VERSION="$(select_secret_version production-json-keys-postgres-backup-password)"
JSON_POSTGRES_DSN_VERSION="$(select_secret_version production-json-keys-postgres-dsn)"
JSON_APP_MASTER_KEY_VERSION="$(select_secret_version production-json-keys-app-master-key)"
unset -f select_secret_version
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Keep an older version enabled while any retained receipt references it; rollback fails closed if a
receipt-owned version is disabled or destroyed.

## 4. Store the protected non-payload release configuration

Complete [Configure hosted Plunk SMTP](./configure-hosted-smtp.md) first. The provider-neutral
runtime contract is authenticated STARTTLS submission on port 587; `sender_domain` repeats the SMTP
host because Authentication uses it for the TLS server name. Initializer principals are foundation
inputs, not a mutable release secret. The active Google account is the fast-path first super-admin;
replace that assignment when the application administrator is another address.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
[[ "$AUTH_SUPER_ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
[[ "$SMTP_HOST" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]
[[ "$SMTP_USERNAME" =~ ^[^[:space:]]{1,320}$ ]]
[[ "$SMTP_SENDER_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
test -n "$SMTP_SENDER_NAME"

RELEASE_CONFIG_FILE="$(mktemp)"
{
jq -n \
  --arg management "$MANAGEMENT_PROJECT_ID" --arg workload "$WORKLOAD_PROJECT_ID" \
  --arg region "$REGION" --arg zone "$DATABASE_ZONE" \
  --arg backup "$BACKUP_BUCKET_NAME" --arg database_ip "$DATABASE_PRIVATE_IP" \
  --arg network "$NETWORK_ID" --arg subnet "$SUBNET_ID" \
  --arg invocation_key "$INVOCATION_TAG_KEY" \
  --arg initializer_tag "$INITIALIZER_TAG_VALUE" --arg internal_tag "$INTERNAL_TAG_VALUE" \
  --arg recovery_tag "$RECOVERY_TAG_VALUE" --arg release_tag "$RELEASE_TAG_VALUE" \
  --arg scheduled_tag "$SCHEDULED_TAG_VALUE" --arg admin "$AUTH_SUPER_ADMIN_EMAIL" \
  --arg smtp "${SMTP_HOST}:587" --arg smtp_domain "$SMTP_HOST" \
  --arg smtp_username "$SMTP_USERNAME" --arg smtp_email "$SMTP_SENDER_EMAIL" \
  --arg smtp_name "$SMTP_SENDER_NAME" \
  --argjson ap "$AUTH_POSTGRES_PASSWORD_VERSION" \
  --argjson ab "$AUTH_POSTGRES_BACKUP_PASSWORD_VERSION" \
  --argjson ad "$AUTH_POSTGRES_DSN_VERSION" --argjson as "$AUTH_SMTP_PASSWORD_VERSION" \
  --argjson aa "$AUTH_SUPER_ADMIN_PASSWORD_VERSION" \
  --argjson jp "$JSON_POSTGRES_PASSWORD_VERSION" \
  --argjson jb "$JSON_POSTGRES_BACKUP_PASSWORD_VERSION" \
  --argjson jd "$JSON_POSTGRES_DSN_VERSION" --argjson jm "$JSON_APP_MASTER_KEY_VERSION" \
  '{
    management_project_id: $management, workload_project_id: $workload,
    region: $region, database_zone: $zone, backup_bucket_name: $backup,
    database_private_ip: $database_ip, network_id: $network, subnet_id: $subnet,
    cloud_run_invocation_tags: {
      key: $invocation_key,
      values: {
        initializer: $initializer_tag, internal: $internal_tag,
        recovery: $recovery_tag, release: $release_tag, scheduled: $scheduled_tag
      }
    },
    authentication: {
      super_admin_email: $admin,
      smtp: {
        address: $smtp, sender_domain: $smtp_domain, username: $smtp_username,
        sender_email: $smtp_email, sender_name: $smtp_name
      }
    },
    quota_expectations: {
      cloud_run_cpu_millicpu: 8000, cloud_run_memory_bytes: 17179869184,
      cloud_run_direct_vpc_instances: 20, compute_cpu: 4
    },
    secret_versions: {
      authentication_postgres_password: $ap,
      authentication_postgres_backup_password: $ab,
      authentication_postgres_dsn: $ad,
      authentication_smtp_password: $as,
      authentication_super_admin_password: $aa,
      json_keys_postgres_password: $jp,
      json_keys_postgres_backup_password: $jb,
      json_keys_postgres_dsn: $jd,
      json_keys_app_master_key: $jm
    }
  }' >"$RELEASE_CONFIG_FILE"

jq -e '(.cloud_run_invocation_tags.values | length == 5) and (.secret_versions | length == 9)' \
  "$RELEASE_CONFIG_FILE" >/dev/null
gh secret set RELEASE_CONFIG_JSON --repo "$REPOSITORY" --env production-release \
  <"$RELEASE_CONFIG_FILE"
} always {
rm -f -- "$RELEASE_CONFIG_FILE"
unset RELEASE_CONFIG_FILE SMTP_USERNAME
}
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

The workflow materializes this document with mode `0600`, never uploads it, and never prints it.
The SMTP username is a non-payload login identifier but stays inside the protected bundle to avoid
publishing tenant metadata. Secret payloads remain only in Secret Manager and are resolved by
dedicated runtime identities.

## 5. Enable the reviewed image families

`deploy/production/images.yaml` contains two enabled four-image families. The first activation PR
fills all slots with the exact GHCR repository, one complete stable
`vMAJOR.MINOR.PATCH` shared by that family, and its exact `sha256:` digest. The schema rejects
branches, prereleases, partial families, unknown slots, moving references, and PostgreSQL other than
major 18. The required pull-request check also rejects a partial family, a digest mutation behind an
unchanged tag, or a service/PostgreSQL major mixed with another concern. Renovate subsequently opens
human-reviewed pull requests only for stable SemVer releases and groups each service family. After
launch, merging such a manifest pull request starts deployment automatically.

For first activation, add deletion approval before merging the exact pull request whose merge commit
will be the `master` commit dispatched for that first release. Compensation may remove all newly
created release resources. If another pull request lands afterward, that newer pull request needs the
label instead because the deletion gate is bound to the exact deployed commit:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
ACTIVATION_PR='replace-with-pull-request-number'
[[ "$ACTIVATION_PR" =~ ^[1-9][0-9]*$ ]]
gh pr edit "$ACTIVATION_PR" --repo "$REPOSITORY" --add-label allow-resource-deletion
gh pr view "$ACTIVATION_PR" --repo "$REPOSITORY" \
  --json labels,reviewDecision,statusCheckRollup \
  --jq '{labels:[.labels[].name],reviewDecision,checks:[.statusCheckRollup[] | {name,status,conclusion}]}'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Later releases need the label only when their sanitized plan contains a deletion, replacement, or
state-forget action.

## 6. Enable releases and observe the exact deployment

For first activation, keep the switch false until sections 1–5 and the backup prerequisites are
complete. Enabling it is a deliberate launch decision; it does not retroactively trigger a manifest
merge that already happened.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
test "$(gh variable get PRODUCTION_RELEASES_ENABLED --repo "$REPOSITORY")" = false
printf 'Type enable-production-releases to authorize launch: '
IFS= read -r RELEASE_CONFIRMATION
test "$RELEASE_CONFIRMATION" = enable-production-releases
gh variable set PRODUCTION_RELEASES_ENABLED --repo "$REPOSITORY" --body true
test "$(gh variable get PRODUCTION_RELEASES_ENABLED --repo "$REPOSITORY")" = true
unset RELEASE_CONFIRMATION
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: both tests print nothing. To freeze new release and rollback runs, set the
variable back to `false`; this does not cancel a workflow that already entered the protected
environment.

For the first activation or an explicit retry, dispatch `deploy` with the repository helper. It
refuses a stale, dirty, or non-`master` checkout and any already active production infrastructure
run, then prints the exact run URL and returns its ID:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
git switch master
git pull --ff-only
test -z "$(git status --porcelain)"
MASTER_SHA="$(git rev-parse HEAD)"
RELEASE_RUN_ID="$(
  EXPECTED_SHA="$MASTER_SHA" ./ops/run-workflow.sh \
    release.yaml run-id --no-wait action=deploy
)"
printf 'Release run ID: %s\n' "$RELEASE_RUN_ID"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Open the printed URL. For a retry that does not require first-launch initialization, wait for it now:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gh run watch "$RELEASE_RUN_ID" --repo "$REPOSITORY" --exit-status
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

On the first launch, skip that watcher and continue with the initializer subsection when the run URL
shows its prompt.

For a later manifest update, do not dispatch a duplicate: the protected merge creates a `push` run.
Select that exact commit automatically and wait for it:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
git switch master
git pull --ff-only
test -z "$(git status --porcelain)"
MASTER_SHA="$(git rev-parse HEAD)"
test "$MASTER_SHA" = "$(gh api "repos/${REPOSITORY}/commits/master" --jq .sha)"
RELEASE_RUNS="$(gh run list --repo "$REPOSITORY" --workflow release.yaml \
  --branch master --commit "$MASTER_SHA" --event push --limit 10 \
  --json databaseId,headSha,displayTitle,status,conclusion,url)"
test "$(jq 'length' <<<"$RELEASE_RUNS")" -eq 1
RELEASE_RUN_ID="$(jq --raw-output '.[0].databaseId' <<<"$RELEASE_RUNS")"
[[ "$RELEASE_RUN_ID" =~ ^[1-9][0-9]*$ ]]
gh run watch "$RELEASE_RUN_ID" --repo "$REPOSITORY" --exit-status
unset RELEASE_RUNS
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Logs contain stable stages, sanitized OpenTofu counts, and execution IDs only—never configuration,
plans, state, image inventories, paired secret/version inventories, or provider diagnostics. The
private receipt binds the exact migration, rotation, backup, restore, monitor, initialization when
applicable, and health-gate evidence to the promoted revisions.

On the first launch, complete the subsection below in the same shell, which retains the validated
variables, then use its final `gh run watch` command to verify the workflow succeeded.

### First launch: provision and run the human-only initializer

Keep the live workflow log open. After migrations, it prints the initializer prompt and waits for an
execution created after that prompt. Authenticate as one of the initializer principals configured in
foundation. Do not use the release service account.

Copy the exact initializer `sha256:` digest from the reviewed
`service-authentication.images.jobs/init` manifest entry. The workflow has already promoted that
digest when it reaches the prompt:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
INIT_DIGEST=''
[[ "$INIT_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]]
INIT_IMAGE="${REGION}-docker.pkg.dev/${WORKLOAD_PROJECT_ID}/agora-production/service-authentication/jobs/init@${INIT_DIGEST}"
INIT_SERVICE_ACCOUNT="agora-auth-initializer@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com"
INIT_JOB_PARENT="//run.googleapis.com/projects/${WORKLOAD_PROJECT_ID}/locations/${REGION}/jobs/agora-authentication-init"
MANAGEMENT_PROJECT_NUMBER="$(gcloud projects describe "$MANAGEMENT_PROJECT_ID" \
  --format='value(projectNumber)')"
[[ "$MANAGEMENT_PROJECT_NUMBER" =~ ^[0-9]+$ ]]

gcloud artifacts docker images describe "$INIT_IMAGE" \
  --project="$WORKLOAD_PROJECT_ID" --format='none'
if gcloud run jobs describe agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --format='none' 2>/dev/null; then
  printf 'STOP: the one-time initializer already exists; use the partial-failure procedure.\n' >&2
  return 1
fi
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Create an inert definition first. This step deliberately includes the exact image, identity,
capacity, and network but no environment variables, secret references, command, arguments, or
execution flag:

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

gcloud run jobs describe agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --format=export
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: deployment succeeds without starting an execution. The exported definition has
the exact digest and service account above, one task, the private network, no `env`, no secret
annotation, and no command or arguments. Stop if any bootstrap value is already present.

Attach the human-only authorization tag before adding bootstrap configuration, then prove it is the
only direct tag:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud resource-manager tags bindings create \
  --tag-value="$INITIALIZER_TAG_VALUE" --parent="$INIT_JOB_PARENT" --location="$REGION"

gcloud resource-manager tags bindings list \
  --parent="$INIT_JOB_PARENT" --location="$REGION" --format=json \
| jq --exit-status --arg expected "$INITIALIZER_TAG_VALUE" '
    ([.[].tagValue] | sort) == ([$expected] | sort)
  '
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: `true`. The job must not carry `release`, `scheduled`, `internal`, or
`recovery`. Routine automation cannot attach the initializer value or use its service account.

Only after that check passes, add the exact non-payload email and two exact cross-project secret
versions. This update does not execute the job:

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
  --set-env-vars="SUPER_ADMIN_EMAIL=${AUTH_SUPER_ADMIN_EMAIL}" \
  --set-secrets="POSTGRES_DSN=projects/${MANAGEMENT_PROJECT_NUMBER}/secrets/production-authentication-postgres-dsn:${AUTH_POSTGRES_DSN_VERSION},SUPER_ADMIN_PASSWORD=projects/${MANAGEMENT_PROJECT_NUMBER}/secrets/production-authentication-super-admin-password:${AUTH_SUPER_ADMIN_PASSWORD_VERSION}"

gcloud resource-manager tags bindings list \
  --parent="$INIT_JOB_PARENT" --location="$REGION" --format=json \
| jq --exit-status --arg expected "$INITIALIZER_TAG_VALUE" '
    ([.[].tagValue] | sort) == ([$expected] | sort)
  '
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: the update finishes without an execution and the tag check remains `true`.
Run exactly one normal execution—never add image, argument, environment, task, timeout, or secret
overrides:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud run jobs execute agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --wait
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

The workflow rejects an absent, failed, stale, or wrong-job execution and atomically writes the
private one-time marker `production/initialization/complete.json`. Wait for the release workflow to
finish successfully, then delete the dormant privileged definition while its initializer tag is
still attached:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gh run watch "$RELEASE_RUN_ID" --repo "$REPOSITORY" --exit-status
gcloud run jobs delete agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --quiet
if gcloud run jobs describe agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --format='none' 2>/dev/null; then
  printf 'STOP: the initializer still exists; keep its initializer tag and investigate.\n' >&2
  return 1
fi
unset INIT_DIGEST INIT_IMAGE INIT_SERVICE_ACCOUNT INIT_JOB_PARENT MANAGEMENT_PROJECT_NUMBER
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Never detach or replace the initializer tag before deletion: an untagged privileged job could be
retagged into a routine invocation class. Later releases are non-interactive, and recovery projects
do not create this job or marker. If no human succeeds within 30 minutes, the release compensates;
follow the partial-failure procedure below and dispatch a fresh run rather than fabricating a marker.

## 7. Verify deployment and rotation

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gh run view "$RELEASE_RUN_ID" --repo "$REPOSITORY" \
  --json headSha,status,conclusion,url,jobs \
  --jq '{headSha,status,conclusion,url,jobs:[.jobs[] | {name,conclusion}]}'
gcloud run services describe agora-json-keys-grpc \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" \
  --format='yaml(metadata.name,metadata.annotations,status.conditions,status.traffic)'
gcloud run services describe agora-authentication-rest \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" \
  --format='yaml(metadata.name,status.conditions,status.traffic,status.url)'
gcloud scheduler jobs describe agora-json-keys-rotation \
  --project="$WORKLOAD_PROJECT_ID" --location="$REGION" \
  --format='yaml(name,state,schedule,timeZone,httpTarget.uri,httpTarget.oauthToken.serviceAccountEmail)'
if gcloud run jobs describe agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --format='none' 2>/dev/null; then
  printf 'STOP: the one-time initializer still exists.\n' >&2
  return 1
fi
for tuple in \
  "jobs/agora-authentication-migrations $RELEASE_TAG_VALUE" \
  "jobs/agora-json-keys-migrations $RELEASE_TAG_VALUE" \
  "jobs/agora-json-keys-rotatekeys $SCHEDULED_TAG_VALUE" \
  "services/agora-json-keys-grpc $INTERNAL_TAG_VALUE"; do
  read -r resource expected <<<"$tuple"
  gcloud resource-manager tags bindings list \
    --parent="//run.googleapis.com/projects/${WORKLOAD_PROJECT_ID}/locations/${REGION}/${resource}" \
    --location="$REGION" --format=json \
  | jq --exit-status --arg expected "$expected" \
      '([.[].tagValue] | sort) == ([$expected] | sort)'
done
gcloud storage ls "gs://${RECEIPT_BUCKET_NAME}/production/success/*.json"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected: the exact commit succeeded; each service has one exact revision at 100%; JSON Keys retains
internal ingress; Authentication is the public HTTPS edge; rotation is enabled at `10 * * * *` UTC
as the scheduler identity; the initializer job is absent; all four tag checks return `true`; and the
newest receipt ends in the release `run-id-attempt`. Do not print a receipt: it is a private recovery
inventory even though it contains no payload secret.

After completing the bounded delivery, bounce, and cap tests in
[Configure hosted Plunk SMTP](./configure-hosted-smtp.md#5-validate-without-exposing-the-credential),
audit the current release's bounded application logs. This deliberately reads each exact deployed
secret into a mode-`0700` scratch directory so it can prove the payload does not occur in logs; no
payload reaches stdout, a process argument, GitHub, or OpenTofu:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
LOG_AUDIT_DIRECTORY="$(mktemp -d)"
chmod 700 "$LOG_AUDIT_DIRECTORY"
{
LOG_AUDIT_FILE="${LOG_AUDIT_DIRECTORY}/cloud-run.json"
gcloud logging read '
  (resource.type="cloud_run_revision" OR resource.type="cloud_run_job")
  (log_id("run.googleapis.com/stdout") OR
   log_id("run.googleapis.com/stderr") OR
   log_id("run.googleapis.com/requests"))
' --project="$WORKLOAD_PROJECT_ID" --freshness=24h --limit=500 \
  --format=json >"$LOG_AUDIT_FILE"

SECRET_PATTERN_ARGUMENTS=()
while IFS=' ' read -r secret version; do
  payload_file="${LOG_AUDIT_DIRECTORY}/${secret}"
  gcloud secrets versions access "$version" --secret="$secret" \
    --project="$MANAGEMENT_PROJECT_ID" --out-file="$payload_file" \
    --quiet >/dev/null
  test -s "$payload_file"
  SECRET_PATTERN_ARGUMENTS+=(--file="$payload_file")
done <<EOF
production-authentication-postgres-password $AUTH_POSTGRES_PASSWORD_VERSION
production-authentication-postgres-backup-password $AUTH_POSTGRES_BACKUP_PASSWORD_VERSION
production-authentication-postgres-dsn $AUTH_POSTGRES_DSN_VERSION
production-authentication-smtp-sender-password $AUTH_SMTP_PASSWORD_VERSION
production-authentication-super-admin-password $AUTH_SUPER_ADMIN_PASSWORD_VERSION
production-json-keys-postgres-password $JSON_POSTGRES_PASSWORD_VERSION
production-json-keys-postgres-backup-password $JSON_POSTGRES_BACKUP_PASSWORD_VERSION
production-json-keys-postgres-dsn $JSON_POSTGRES_DSN_VERSION
production-json-keys-app-master-key $JSON_APP_MASTER_KEY_VERSION
EOF

if LC_ALL=C grep --fixed-strings "${SECRET_PATTERN_ARGUMENTS[@]}" \
  "$LOG_AUDIT_FILE" >/dev/null; then
  printf 'STOP: an exact deployed secret payload occurs in Cloud Run logs.\n' >&2
  false
fi

jq --exit-status '
  length > 0 and
  any(.[]; has("httpRequest") or has("jsonPayload")) and
  ([
    .[] | .jsonPayload? | .. | objects | keys[] |
    ascii_downcase | gsub("[_-]"; "") |
    select(
      . == "authorization" or . == "headers" or . == "requestbody" or
      . == "requestpayload" or . == "environment" or . == "env" or
      . == "password" or . == "dsn" or . == "smtpcredential"
    )
  ] | length == 0) and
  ([
    .[] | (.jsonPayload?, .textPayload?) | .. | strings |
    select(test(
      "(?i)(postgres(?:ql)?://[^[:space:]@]+:[^[:space:]@]+@|" +
      "authorization[[:space:]_:=\\\"]+(bearer|basic)|" +
      "smtp_sender_password[[:space:]]*=|postgres_dsn[[:space:]]*=|" +
      "-----BEGIN [A-Z ]*PRIVATE KEY-----)"
    ))
  ] | length == 0)
' "$LOG_AUDIT_FILE" >/dev/null
} always {
rm -rf -- "$LOG_AUDIT_DIRECTORY"
unset LOG_AUDIT_DIRECTORY LOG_AUDIT_FILE SECRET_PATTERN_ARGUMENTS payload_file secret version
}
printf 'Bounded production logs contain no deployed secret or forbidden payload field.\n'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: only the final generic success line. A zero-entry result fails because it does
not prove structured logging. The audit checks exact deployed payloads, authorization/credential
shapes, DSN userinfo, private-key material, environment dumps, headers, and request-body fields.
Never print the matching line when it fails; freeze releases, let the scoped cleanup remove the
sensitive scratch directory, record non-secret incident metadata, revoke exposed credentials, and follow
[Add or rotate a secret version](./secret-versions.md).

## 8. Restore an exact prior receipt

Rollback is for a bad application release with healthy data. Choose the unpadded `run-id-attempt`
from a prior private success object or Actions run:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud storage ls "gs://${RECEIPT_BUCKET_NAME}/production/success/*.json"
TARGET_RECEIPT=''
[[ "$TARGET_RECEIPT" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]]
git switch master
git pull --ff-only
test -z "$(git status --porcelain)"
MASTER_SHA="$(git rev-parse HEAD)"
ROLLBACK_RUN_ID="$(
  EXPECTED_SHA="$MASTER_SHA" ./ops/run-workflow.sh \
    release.yaml run-id action=rollback target_receipt="$TARGET_RECEIPT"
)"
printf 'Rollback run ID: %s\n' "$ROLLBACK_RUN_ID"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

The workflow treats the newest success receipt as the current live-state preflight and the selected
receipt as the rollback destination. It validates both, requires the live database metadata to match
the newest receipt before any change, confirms every destination-owned secret version remains
enabled, routes traffic back, recreates prior templates under fresh revision names, restores the
selected database container metadata, proves convergence, and writes a new `rollback` receipt. It does not reverse
migrations or restore data. If compensation or rollback fails, freeze writes and use
[Recover into a disposable project](./disaster-recovery.md); if only data is damaged and the workload
project is trustworthy, use [Back up and restore PostgreSQL](./backup-and-restore-postgresql.md).

## Initializer partial-failure recovery

- If the release compensates before the initializer exists, create nothing. Diagnose the workflow
  and dispatch a fresh release.
- If an inert untagged job exists because tag attachment failed, verify its exported definition has
  no environment or secrets. Attach only `INITIALIZER_TAG_VALUE`, recheck the sole tag, and continue
  only while a fresh release is waiting. If that invariant is uncertain, delete the inert job and
  restart the two-phase procedure.
- If any untagged initializer already contains bootstrap configuration, cancel every production
  writer and treat it as an IAM incident. Do not attach a routine tag or execute it. Preserve audit
  evidence, delete the job, verify it is absent, and review who created or updated it before retrying.
- If an initializer-tagged job remains after compensation, keep that tag attached. Delete the job
  before a fresh dispatch, or rerun it without overrides only after the fresh workflow reaches its
  prompt. A new gate deliberately ignores executions created before its own start time.
- If deletion fails after success, leave the initializer tag attached and do not add another tag.
  The dormant definition remains human-only; resolve the control-plane error and delete it before the
  next routine release.

Never create the initialization marker manually. Its create-only write and post-prompt successful
execution are the evidence that makes later releases non-interactive.
