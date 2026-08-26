# Deploy and roll back production

Use this runbook for a reviewed release of JSON Keys and Authentication, or to restore the whole
application to one exact prior successful receipt. The workflow is manual-only: a manifest merge
never deploys by itself, and a branch or pull request never receives Google credentials.

Official references: [Cloud Run revisions](https://cloud.google.com/run/docs/managing/revisions),
[traffic migration and rollback](https://cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration),
[executing Cloud Run jobs](https://cloud.google.com/run/docs/execute/jobs),
[deploying Cloud Run jobs](https://cloud.google.com/sdk/gcloud/reference/run/jobs/deploy),
[tagging Cloud Run jobs](https://cloud.google.com/run/docs/configuring/jobs/tags),
[Cloud Run job secrets](https://cloud.google.com/run/docs/configuring/jobs/secrets),
[Artifact Registry image copying](https://cloud.google.com/artifact-registry/docs/docker/copy-images),
[Secret Manager version states](https://cloud.google.com/secret-manager/docs/managing-secret-versions),
and [GitHub artifact attestations](https://docs.github.com/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).

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
- Each source image has a GitHub producer attestation and a stable complete SemVer tag.
- `production-release` accepts only protected branches and contains only its release WIF coordinates
  plus `RELEASE_CONFIG_JSON`.
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

```bash
set -euo pipefail
set +x
umask 077

REPOSITORY='a-novel/infra'
REGION='europe-west1'
DATABASE_ZONE='europe-west1-b'

git switch master
git pull --ff-only
test -z "$(git status --porcelain)"
MASTER_SHA="$(git rev-parse HEAD)"
test "$MASTER_SHA" = "$(gh api "repos/${REPOSITORY}/commits/master" --jq .sha)"

gh api "repos/${REPOSITORY}/environments/production-release" \
  --jq '{name,deployment_branch_policy,protection_rules}'
gh variable list --repo "$REPOSITORY" --env production-release
gh secret list --repo "$REPOSITORY" --env production-release
```

Expected safe result: protected branches, no custom branch policy, exactly
`GCP_RELEASE_WORKLOAD_IDENTITY_PROVIDER` and `GCP_RELEASE_SERVICE_ACCOUNT`, and—after section 4—only
`RELEASE_CONFIG_JSON`. Routine release has no second approval queue because workflow code and the
manifest already passed the protected pull-request merge gate.

Create the deletion label if absent:

```bash
gh label create allow-resource-deletion \
  --repo "$REPOSITORY" \
  --color B60205 \
  --description 'Explicit maintainer approval for managed-resource deletion at merge' \
  --force
```

The gate replays the PR timeline. It accepts the label only when a maintainer with write, maintain,
or admin permission added it and it remained present when that exact PR merged. A post-merge label
does not authorize deletion.

## 2. Collect foundation-owned coordinates

```bash
read -r -p 'Management project ID: ' MANAGEMENT_PROJECT_ID
read -r -p 'Production workload project ID: ' WORKLOAD_PROJECT_ID
[[ "$MANAGEMENT_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "$WORKLOAD_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "$MANAGEMENT_PROJECT_ID" != "$WORKLOAD_PROJECT_ID" ]]

BACKUP_BUCKET_NAME="$(gh variable get GCP_BACKUP_BUCKET --repo "$REPOSITORY")"
RECEIPT_BUCKET_NAME="$(gh variable get GCP_RECEIPT_BUCKET --repo "$REPOSITORY")"
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
```

Expected safe result: one `agora-database-*` member with an RFC 1918 address, one custom-mode
network, one `10.20.0.0/24` subnet with Private Google Access, and one permanent ID for each of the
five invocation classes. Do not print instance metadata or OpenTofu outputs; either can include
release configuration.

## 3. Select and verify exact secret versions

Enter only numeric version IDs; never retrieve payloads:

```bash
read -r -p 'Authentication PostgreSQL owner password version: ' AUTH_POSTGRES_PASSWORD_VERSION
read -r -p 'Authentication PostgreSQL backup password version: ' AUTH_POSTGRES_BACKUP_PASSWORD_VERSION
read -r -p 'Authentication PostgreSQL DSN version: ' AUTH_POSTGRES_DSN_VERSION
read -r -p 'Authentication SMTP password version: ' AUTH_SMTP_PASSWORD_VERSION
read -r -p 'Authentication super-admin password version: ' AUTH_SUPER_ADMIN_PASSWORD_VERSION
read -r -p 'JSON Keys PostgreSQL owner password version: ' JSON_POSTGRES_PASSWORD_VERSION
read -r -p 'JSON Keys PostgreSQL backup password version: ' JSON_POSTGRES_BACKUP_PASSWORD_VERSION
read -r -p 'JSON Keys PostgreSQL DSN version: ' JSON_POSTGRES_DSN_VERSION
read -r -p 'JSON Keys application master-key version: ' JSON_APP_MASTER_KEY_VERSION

for version in "$AUTH_POSTGRES_PASSWORD_VERSION" "$AUTH_POSTGRES_BACKUP_PASSWORD_VERSION" \
  "$AUTH_POSTGRES_DSN_VERSION" "$AUTH_SMTP_PASSWORD_VERSION" \
  "$AUTH_SUPER_ADMIN_PASSWORD_VERSION" "$JSON_POSTGRES_PASSWORD_VERSION" \
  "$JSON_POSTGRES_BACKUP_PASSWORD_VERSION" "$JSON_POSTGRES_DSN_VERSION" \
  "$JSON_APP_MASTER_KEY_VERSION"; do
  [[ "$version" =~ ^[1-9][0-9]*$ ]]
done

check_secret_version() {
  test "$(gcloud secrets versions describe "$2" --secret="$1" \
    --project="$MANAGEMENT_PROJECT_ID" --format='value(state)')" = ENABLED
}
check_secret_version production-authentication-postgres-password "$AUTH_POSTGRES_PASSWORD_VERSION"
check_secret_version production-authentication-postgres-backup-password "$AUTH_POSTGRES_BACKUP_PASSWORD_VERSION"
check_secret_version production-authentication-postgres-dsn "$AUTH_POSTGRES_DSN_VERSION"
check_secret_version production-authentication-smtp-sender-password "$AUTH_SMTP_PASSWORD_VERSION"
check_secret_version production-authentication-super-admin-password "$AUTH_SUPER_ADMIN_PASSWORD_VERSION"
check_secret_version production-json-keys-postgres-password "$JSON_POSTGRES_PASSWORD_VERSION"
check_secret_version production-json-keys-postgres-backup-password "$JSON_POSTGRES_BACKUP_PASSWORD_VERSION"
check_secret_version production-json-keys-postgres-dsn "$JSON_POSTGRES_DSN_VERSION"
check_secret_version production-json-keys-app-master-key "$JSON_APP_MASTER_KEY_VERSION"
```

Keep an older version enabled while any retained receipt references it; rollback fails closed if a
receipt-owned version is disabled or destroyed.

## 4. Store the protected non-payload release configuration

SMTP is fixed to authenticated TLS submission on port 587, and the host and `sender_domain` are
identical. Initializer principals are foundation inputs, not a mutable release secret.

```bash
read -r -p 'First super-admin email: ' AUTH_SUPER_ADMIN_EMAIL
read -r -p 'SMTP DNS host (without port): ' SMTP_HOST
read -r -p 'SMTP sender email: ' SMTP_SENDER_EMAIL
read -r -p 'SMTP sender display name: ' SMTP_SENDER_NAME

[[ "$AUTH_SUPER_ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
[[ "$SMTP_HOST" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]
[[ "$SMTP_SENDER_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
test -n "$SMTP_SENDER_NAME"

RELEASE_CONFIG_FILE="$(mktemp)"
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
  --arg smtp_email "$SMTP_SENDER_EMAIL" --arg smtp_name "$SMTP_SENDER_NAME" \
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
      smtp: {address: $smtp, sender_domain: $smtp_domain, sender_email: $smtp_email, sender_name: $smtp_name}
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
rm -f -- "$RELEASE_CONFIG_FILE"
unset RELEASE_CONFIG_FILE
```

The workflow materializes this document with mode `0600`, never uploads it, and never prints it.
Secret payloads remain only in Secret Manager and are resolved by dedicated runtime identities.

## 5. Enable the reviewed image families

`deploy/production/images.yaml` contains two four-image families. The first activation PR sets both
components to `enabled: true` and fills all slots with the exact GHCR repository, one complete stable
`vMAJOR.MINOR.PATCH` shared by that family, and its exact `sha256:` digest. The schema rejects
branches, prereleases, partial families, unknown slots, moving references, and PostgreSQL other than
major 18. Renovate subsequently updates each family only for stable SemVer releases; its merge still
does not deploy.

For first activation, add deletion approval before merge because compensation may remove all newly
created release resources:

```bash
read -r -p 'First-activation pull request number: ' ACTIVATION_PR
[[ "$ACTIVATION_PR" =~ ^[1-9][0-9]*$ ]]
gh pr edit "$ACTIVATION_PR" --repo "$REPOSITORY" --add-label allow-resource-deletion
gh pr view "$ACTIVATION_PR" --repo "$REPOSITORY" \
  --json labels,reviewDecision,statusCheckRollup \
  --jq '{labels:[.labels[].name],reviewDecision,checks:[.statusCheckRollup[] | {name,status,conclusion}]}'
```

Later releases need the label only when their sanitized plan contains a deletion, replacement, or
state-forget action.

## 6. Dispatch and observe a release

```bash
git pull --ff-only
test -z "$(git status --porcelain)"
MASTER_SHA="$(git rev-parse HEAD)"
test "$MASTER_SHA" = "$(gh api "repos/${REPOSITORY}/commits/master" --jq .sha)"

gh workflow run release.yaml --repo "$REPOSITORY" --ref master -f action=deploy
gh run list --repo "$REPOSITORY" --workflow release.yaml --branch master \
  --event workflow_dispatch --limit 5 \
  --json databaseId,headSha,displayTitle,status,conclusion,url
```

Select `production deploy` with `headSha == MASTER_SHA`, then:

```bash
read -r -p 'Release workflow run ID: ' RELEASE_RUN_ID
test "$(gh api "repos/${REPOSITORY}/actions/runs/${RELEASE_RUN_ID}" --jq .head_sha)" = "$MASTER_SHA"
gh run watch "$RELEASE_RUN_ID" --repo "$REPOSITORY" --exit-status
```

Logs contain stable stages, sanitized OpenTofu counts, and execution IDs only—never configuration,
plans, state, image inventories, paired secret/version inventories, or provider diagnostics. The
private receipt binds the exact migration, rotation, backup, restore, monitor, initialization when
applicable, and health-gate evidence to the promoted revisions.

On the first launch, `gh run watch` remains attached while the workflow waits for initialization.
When the initializer prompt appears, press `Ctrl-C`; this stops only the local watcher, not the
workflow. Complete the subsection below in the same shell, which retains the validated variables,
then use its final `gh run watch` command to verify the workflow succeeded.

### First launch: provision and run the human-only initializer

Keep the live workflow log open. After migrations, it prints the initializer prompt and waits for an
execution created after that prompt. Authenticate as one of the initializer principals configured in
foundation. Do not use the release service account.

Copy the exact initializer `sha256:` digest from the reviewed
`service-authentication.images.jobs/init` manifest entry. The workflow has already promoted that
digest when it reaches the prompt:

```bash
read -r -p 'Reviewed Authentication initializer sha256 digest: ' INIT_DIGEST
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
  exit 1
fi
```

Create an inert definition first. This step deliberately includes the exact image, identity,
capacity, and network but no environment variables, secret references, command, arguments, or
execution flag:

```bash
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
```

Expected safe result: deployment succeeds without starting an execution. The exported definition has
the exact digest and service account above, one task, the private network, no `env`, no secret
annotation, and no command or arguments. Stop if any bootstrap value is already present.

Attach the human-only authorization tag before adding bootstrap configuration, then prove it is the
only direct tag:

```bash
gcloud resource-manager tags bindings create \
  --tag-value="$INITIALIZER_TAG_VALUE" --parent="$INIT_JOB_PARENT" --location="$REGION"

gcloud resource-manager tags bindings list \
  --parent="$INIT_JOB_PARENT" --location="$REGION" --format=json \
| jq --exit-status --arg expected "$INITIALIZER_TAG_VALUE" '
    ([.[].tagValue] | sort) == ([$expected] | sort)
  '
```

Expected safe result: `true`. The job must not carry `release`, `scheduled`, `internal`, or
`recovery`. Routine automation cannot attach the initializer value or use its service account.

Only after that check passes, add the exact non-payload email and two exact cross-project secret
versions. This update does not execute the job:

```bash
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
```

Expected safe result: the update finishes without an execution and the tag check remains `true`.
Run exactly one normal execution—never add image, argument, environment, task, timeout, or secret
overrides:

```bash
gcloud run jobs execute agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --wait
```

The workflow rejects an absent, failed, stale, or wrong-job execution and atomically writes the
private one-time marker `production/initialization/complete.json`. Wait for the release workflow to
finish successfully, then delete the dormant privileged definition while its initializer tag is
still attached:

```bash
gh run watch "$RELEASE_RUN_ID" --repo "$REPOSITORY" --exit-status
gcloud run jobs delete agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --quiet
if gcloud run jobs describe agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --format='none' 2>/dev/null; then
  printf 'STOP: the initializer still exists; keep its initializer tag and investigate.\n' >&2
  exit 1
fi
unset INIT_DIGEST INIT_IMAGE INIT_SERVICE_ACCOUNT INIT_JOB_PARENT MANAGEMENT_PROJECT_NUMBER
```

Never detach or replace the initializer tag before deletion: an untagged privileged job could be
retagged into a routine invocation class. Later releases are non-interactive, and recovery projects
do not create this job or marker. If no human succeeds within 30 minutes, the release compensates;
follow the partial-failure procedure below and dispatch a fresh run rather than fabricating a marker.

## 7. Verify deployment and rotation

```bash
gh run view "$RELEASE_RUN_ID" --repo "$REPOSITORY" \
  --json headSha,status,conclusion,url,jobs \
  --jq '{headSha,status,conclusion,url,jobs:[.jobs[] | {name,conclusion}]}'
gcloud run services describe agora-json-keys \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" \
  --format='yaml(metadata.name,metadata.annotations,status.conditions,status.traffic)'
gcloud run services describe agora-authentication \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" \
  --format='yaml(metadata.name,status.conditions,status.traffic,status.url)'
gcloud scheduler jobs describe agora-json-keys-rotation \
  --project="$WORKLOAD_PROJECT_ID" --location="$REGION" \
  --format='yaml(name,state,schedule,timeZone,httpTarget.uri,httpTarget.oauthToken.serviceAccountEmail)'
if gcloud run jobs describe agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --format='none' 2>/dev/null; then
  printf 'STOP: the one-time initializer still exists.\n' >&2
  exit 1
fi
for tuple in \
  "jobs/agora-authentication-migrations $RELEASE_TAG_VALUE" \
  "jobs/agora-json-keys-migrations $RELEASE_TAG_VALUE" \
  "jobs/agora-json-keys-rotatekeys $SCHEDULED_TAG_VALUE" \
  "services/agora-json-keys $INTERNAL_TAG_VALUE"; do
  read -r resource expected <<<"$tuple"
  gcloud resource-manager tags bindings list \
    --parent="//run.googleapis.com/projects/${WORKLOAD_PROJECT_ID}/locations/${REGION}/${resource}" \
    --location="$REGION" --format=json \
  | jq --exit-status --arg expected "$expected" \
      '([.[].tagValue] | sort) == ([$expected] | sort)'
done
gcloud storage ls "gs://${RECEIPT_BUCKET_NAME}/production/success/*.json"
```

Expected: the exact commit succeeded; each service has one exact revision at 100%; JSON Keys retains
internal ingress; Authentication is the public HTTPS edge; rotation is enabled at `10 * * * *` UTC
as the scheduler identity; the initializer job is absent; all four tag checks return `true`; and the
newest receipt ends in the release `run-id-attempt`. Do not print a receipt: it is a private recovery
inventory even though it contains no payload secret.

## 8. Restore an exact prior receipt

Rollback is for a bad application release with healthy data. Choose the unpadded `run-id-attempt`
from a prior private success object or Actions run:

```bash
gcloud storage ls "gs://${RECEIPT_BUCKET_NAME}/production/success/*.json"
read -r -p 'Exact prior receipt run-id-attempt: ' TARGET_RECEIPT
[[ "$TARGET_RECEIPT" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]]
gh workflow run release.yaml --repo "$REPOSITORY" --ref master \
  -f action=rollback -f target_receipt="$TARGET_RECEIPT"
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
