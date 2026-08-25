# Deploy and roll back production

Use this runbook for a reviewed release of JSON Keys and Authentication, or to restore the whole
application to one exact prior successful receipt. The workflow is manual-only: a manifest merge
never deploys by itself, and a branch or pull request never receives Google credentials.

Official references: [Cloud Run revisions](https://cloud.google.com/run/docs/managing/revisions),
[traffic migration and rollback](https://cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration),
[executing Cloud Run jobs](https://cloud.google.com/run/docs/execute/jobs),
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

The Authentication initializer is never automated. Only configured human `user:` or `group:`
principals receive normal invocation on that job. Release, recovery, and scheduler identities cannot
execute it, and no principal receives `run.jobs.runWithOverrides`. JSON Keys rotation is automated
separately: release runs it once after migration, then Cloud Scheduler evaluates the idempotent job
at minute 10 every hour.

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
```

Expected safe result: one `agora-database-*` member with an RFC 1918 address, one custom-mode
network, and one `10.20.0.0/24` subnet with Private Google Access. Do not print instance metadata or
OpenTofu outputs; either can include release configuration.

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

Choose at least one named human/group initializer. SMTP is fixed to authenticated TLS submission on
port 587, and the host and `sender_domain` are identical.

```bash
read -r -p 'Initializer IAM member (user: or group:): ' AUTH_INITIALIZER_PRINCIPAL
read -r -p 'First super-admin email: ' AUTH_SUPER_ADMIN_EMAIL
read -r -p 'SMTP DNS host (without port): ' SMTP_HOST
read -r -p 'SMTP sender email: ' SMTP_SENDER_EMAIL
read -r -p 'SMTP sender display name: ' SMTP_SENDER_NAME

[[ "$AUTH_INITIALIZER_PRINCIPAL" =~ ^(user|group):[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
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
  --arg initializer "$AUTH_INITIALIZER_PRINCIPAL" --arg admin "$AUTH_SUPER_ADMIN_EMAIL" \
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
    authentication_initializer_principals: [$initializer],
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

jq -e '(.authentication_initializer_principals | length >= 1) and (.secret_versions | length == 9)' \
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

### First launch: run the one human-only initializer

Keep the live workflow log open. After migrations, it prints the initializer prompt and waits for an
execution created after that prompt. Authenticate as a configured initializer and run exactly:

```bash
gcloud run jobs execute agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" --wait
```

Do not add image, argument, environment, task, timeout, or other overrides. The workflow rejects an
absent, failed, stale, or wrong-job execution and atomically writes the private one-time marker
`production/initialization/complete.json`. Later releases become non-interactive. Recovery projects
do not create this job or marker. If no human succeeds within 30 minutes, the release compensates;
diagnose and dispatch a fresh run rather than fabricating the marker.

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
gcloud run jobs get-iam-policy agora-authentication-init \
  --project="$WORKLOAD_PROJECT_ID" --region="$REGION" \
  --format='table(bindings.role,bindings.members)'
gcloud storage ls "gs://${RECEIPT_BUCKET_NAME}/production/success/*.json"
```

Expected: the exact commit succeeded; each service has one exact revision at 100%; JSON Keys retains
internal ingress; Authentication is the public HTTPS edge; rotation is enabled at `10 * * * *` UTC
as the scheduler identity; initializer invokers are only named humans/groups; and the newest receipt
ends in the release `run-id-attempt`. Do not print a receipt: it is a private recovery inventory even
though it contains no payload secret.

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

The workflow validates the receipt, confirms every receipt-owned secret version remains enabled,
routes traffic back, recreates prior templates under fresh revision names, restores database
container metadata, proves convergence, and writes a new `rollback` receipt. It does not reverse
migrations or restore data. If compensation or rollback fails, freeze writes and use
[Recover into a disposable project](./disaster-recovery.md); if only data is damaged and the workload
project is trustworthy, use [Back up and restore PostgreSQL](./backup-and-restore-postgresql.md).
