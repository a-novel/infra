# Recover production into a disposable project

Use this runbook for a clean-room recovery drill or a declared incident when the production workload
project is no longer trusted. It builds a different Google Cloud project from code, restores two exact
logical backups, and deploys one exact successful application receipt. Production is never repaired
in place and the recovered services remain internal until a separate, reviewed cutover decision.

Official references: [project creation and management](https://cloud.google.com/resource-manager/docs/creating-managing-projects),
[Cloud Billing IAM](https://cloud.google.com/billing/docs/how-to/billing-access),
[Cloud Storage preconditions](https://cloud.google.com/storage/docs/request-preconditions),
[Cloud Run internal ingress](https://cloud.google.com/run/docs/securing/ingress),
[IAP TCP forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding), and
[service-to-service authentication](https://cloud.google.com/run/docs/authenticating/service-to-service).

## Recovery contract

- The replacement project ID must be new and different from production.
- Recovery uses its own WIF identity, protected environment, state suffix, exact plan, and receipt
  prefix. It cannot overwrite production state or a production release receipt.
- The compiler keeps the receipt-owned production database address solely as archive provenance and
  uses the new foundation output as the distinct restore target; the recovery job rejects a manifest
  whose recorded source host differs.
- Production lets the GitHub recovery identity read receipt-owned registry images, committed backup
  manifests, and successful receipts, but never a database dump or secret payload. The replacement
  restore runtime receives read-only backup objects and only the exact secret versions its contract
  needs. Neither identity gets production image write or release-job execution.
- Temporary parent, billing, and management-metadata authority is added by a human only around the
  replacement foundation apply, then removed.
- The replacement project grants foundation and release control only to the recovery identity; the
  production foundation/release identities receive no authority there.
- The two selected backup manifests must match the source project, PostgreSQL 18, and the database
  images recorded by the selected receipt. Each recovery job refuses a non-empty target database.
- Authentication initialization, schedulers, backup writers, and public ingress are absent. Data is
  restored first; services appear only after both recovery jobs complete.
- The operator must type the replacement project name and record the expected user-visible lost-write
  window. The workflow writes a separate immutable recovery receipt.

This path is intentionally not an automatic public failover. Making a recovered project the new
production plane changes DNS, public exposure, billing ownership, state boundaries, backup writers,
and automation trust. Handle that as a separately reviewed incident change after the internal checks
below pass; do not improvise a public endpoint during restore.

## Preconditions and stop conditions

- The management project, state bucket, backup bucket, receipt bucket, WIF providers, and secret
  containers are trusted and accessible.
- Bootstrap has converged after the `infraRecoveryMetadataAdmin` custom role was added.
- `production-recovery` requires an independent reviewer, prevents self-review and administrator
  bypass, and accepts protected branches only.
- At least one valid deployment receipt and one retained committed logical backup per database exist.
- The incident commander froze application writers or explicitly accepted continued writes being
  outside the selected recovery points.
- The operator has parent/project creation and billing-policy authority for the temporary grants.

Stop if the target equals production, an exact backup or receipt is unavailable, a secret version is
disabled, a source image lacks its receipt tag, the plan touches production state, the restore target
is non-empty, or any recovered service becomes publicly reachable.

## 1. Declare the target, receipt, and recovery points

Use a private terminal with tracing disabled:

```bash
set -euo pipefail
set +x
umask 077

REPOSITORY='a-novel/infra'
REGION='europe-west1'
DATABASE_ZONE='europe-west1-b'

read -r -p 'Management project ID: ' MANAGEMENT_PROJECT_ID
read -r -p 'Failed/source workload project ID: ' SOURCE_PROJECT_ID
read -r -p 'New replacement project ID: ' REPLACEMENT_PROJECT_ID
read -r -p 'Billing account ID: ' BILLING_ACCOUNT_ID
read -r -p 'Organization ID, or blank: ' ORGANIZATION_ID
read -r -p 'Folder ID, or blank: ' FOLDER_ID
read -r -p 'Exact successful receipt run-id-attempt: ' TARGET_RECEIPT

[[ "$MANAGEMENT_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "$SOURCE_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "$REPLACEMENT_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "$REPLACEMENT_PROJECT_ID" != "$SOURCE_PROJECT_ID" ]]
[[ "$REPLACEMENT_PROJECT_ID" != "$MANAGEMENT_PROJECT_ID" ]]
[[ "$BILLING_ACCOUNT_ID" =~ ^[0-9A-Z]{6}-[0-9A-Z]{6}-[0-9A-Z]{6}$ ]]
[[ -z "$ORGANIZATION_ID" || "$ORGANIZATION_ID" =~ ^[0-9]+$ ]]
[[ -z "$FOLDER_ID" || "$FOLDER_ID" =~ ^[0-9]+$ ]]
[[ -z "$ORGANIZATION_ID" || -z "$FOLDER_ID" ]]
[[ "$TARGET_RECEIPT" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]]

BACKUP_BUCKET="$(gh variable get GCP_BACKUP_BUCKET --repo "$REPOSITORY")"
RECEIPT_BUCKET="$(gh variable get GCP_RECEIPT_BUCKET --repo "$REPOSITORY")"
RECOVERY_ACCOUNT="infra-recovery@${MANAGEMENT_PROJECT_ID}.iam.gserviceaccount.com"
RECOVERY_MEMBER="serviceAccount:${RECOVERY_ACCOUNT}"
RECOVERY_METADATA_ROLE="projects/${MANAGEMENT_PROJECT_ID}/roles/infraRecoveryMetadataAdmin"

if gcloud projects describe "$REPLACEMENT_PROJECT_ID" >/dev/null 2>&1; then
  printf 'STOP: replacement project already exists or is visible.\n' >&2
  exit 1
fi

gcloud storage ls "gs://${RECEIPT_BUCKET}/production/success/*.json"
gcloud storage ls "gs://${BACKUP_BUCKET}/v1/json-keys/attempts/*/completed.manifest"
gcloud storage ls "gs://${BACKUP_BUCKET}/v1/authentication/attempts/*/completed.manifest"
```

Choose the exact attempt-directory basename from each list:

```bash
read -r -p 'JSON Keys backup attempt: ' JSON_KEYS_ATTEMPT
read -r -p 'Authentication backup attempt: ' AUTHENTICATION_ATTEMPT
[[ "$JSON_KEYS_ATTEMPT" =~ ^[0-9]+-[a-z0-9-]{1,63}-[0-9]+$ ]]
[[ "$AUTHENTICATION_ATTEMPT" =~ ^[0-9]+-[a-z0-9-]{1,63}-[0-9]+$ ]]

for tuple in \
  "json-keys ${JSON_KEYS_ATTEMPT}" \
  "authentication ${AUTHENTICATION_ATTEMPT}"; do
  read -r key attempt <<<"$tuple"
  gcloud storage cat \
    "gs://${BACKUP_BUCKET}/v1/${key}/attempts/${attempt}/completed.manifest" \
    | sed -n -e 's/^completed_utc=/completed_utc=/p' -e 's/^completed_epoch=/completed_epoch=/p'
done
```

Only the two completion timestamps may be copied into the incident record. Do not publish the full
manifests. Write a concise, bounded acknowledgement such as `JSON Keys writes after <UTC> and
Authentication writes after <UTC> may be absent`:

```bash
read -r -p 'Acknowledged lost-write window (max 500 characters): ' LOST_WRITE_WINDOW
test -n "$LOST_WRITE_WINDOW"
test "${#LOST_WRITE_WINDOW}" -le 500
```

## 2. Grant temporary creation and metadata authority

The bootstrap custom role changes only IAM on the nine secret containers and backup bucket. It cannot
read/write backup objects or add/read/destroy a secret version. Grant it on the management project:

```bash
gcloud projects add-iam-policy-binding "$MANAGEMENT_PROJECT_ID" \
  --member="$RECOVERY_MEMBER" --role="$RECOVERY_METADATA_ROLE" --condition=None
gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT_ID" \
  --member="$RECOVERY_MEMBER" --role=roles/billing.user --condition=None
gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT_ID" \
  --member="$RECOVERY_MEMBER" --role=roles/billing.costsManager --condition=None
```

For an existing folder or organization, grant Project Creator at exactly one parent:

```bash
if [[ -n "$FOLDER_ID" ]]; then
  gcloud resource-manager folders add-iam-policy-binding "$FOLDER_ID" \
    --member="$RECOVERY_MEMBER" --role=roles/resourcemanager.projectCreator --condition=None
elif [[ -n "$ORGANIZATION_ID" ]]; then
  gcloud organizations add-iam-policy-binding "$ORGANIZATION_ID" \
    --member="$RECOVERY_MEMBER" --role=roles/resourcemanager.projectCreator --condition=None
else
  printf 'Standalone path: the operator must create and bill one empty project.\n'
fi
```

For the standalone path only, create the empty project manually and let the reviewed declarative
import adopt it. Do not enable APIs or create a network:

```bash
if [[ -z "$ORGANIZATION_ID" && -z "$FOLDER_ID" ]]; then
  gcloud projects create "$REPLACEMENT_PROJECT_ID" \
    --name='Agora recovery' --set-as-default=false
  gcloud billing projects link "$REPLACEMENT_PROJECT_ID" \
    --billing-account="$BILLING_ACCOUNT_ID"
  gcloud projects add-iam-policy-binding "$REPLACEMENT_PROJECT_ID" \
    --member="$RECOVERY_MEMBER" --role=roles/owner --condition=None
fi
```

The temporary Owner is unavoidable only for adopting a parentless project. It is removed immediately
after the exact foundation converges. Never grant Owner on the management or production project.

## 3. Plan and apply the disposable foundation

```bash
MASTER_SHA="$(gh api "repos/${REPOSITORY}/commits/master" --jq .sha)"
gh workflow run recovery.yaml --repo "$REPOSITORY" --ref master \
  -f operation=plan-workload \
  -f replacement_project_id="$REPLACEMENT_PROJECT_ID" \
  -f target_receipt="$TARGET_RECEIPT"
gh run list --repo "$REPOSITORY" --workflow recovery.yaml --branch master \
  --event workflow_dispatch --limit 5 \
  --json databaseId,headSha,displayTitle,status,conclusion,url
```

Select `recovery plan-workload <replacement>` with `headSha == MASTER_SHA`, then:

```bash
read -r -p 'Recovery plan run ID: ' PLAN_RUN_ID
test "$(gh api "repos/${REPOSITORY}/actions/runs/${PLAN_RUN_ID}" --jq .head_sha)" = "$MASTER_SHA"
gh run watch "$PLAN_RUN_ID" --repo "$REPOSITORY" --exit-status
PLAN_ATTEMPT="$(gh api "repos/${REPOSITORY}/actions/runs/${PLAN_RUN_ID}" --jq .run_attempt)"
PLAN_ID="${PLAN_RUN_ID}-${PLAN_ATTEMPT}"
```

Review the sanitized counts. They may target only state suffix
`foundation/recovery/<replacement-project>`. Confirm `master` is unchanged and dispatch exact apply:

```bash
test "$(gh api "repos/${REPOSITORY}/commits/master" --jq .sha)" = "$MASTER_SHA"
gh workflow run recovery.yaml --repo "$REPOSITORY" --ref master \
  -f operation=apply-workload \
  -f replacement_project_id="$REPLACEMENT_PROJECT_ID" \
  -f target_receipt="$TARGET_RECEIPT" \
  -f plan_id="$PLAN_ID"
```

Approve `production-recovery` and watch the exact `apply-workload` run to success. The saved plan is
commit-, root-, project-state-suffix-, hash-, and 24-hour-bound and can be consumed once.

## 4. Remove temporary authority before restoring data

The converged replacement project now grants code-managed authority to recovery itself, so remove all
bootstrap grants before any secret-backed recovery job runs:

```bash
gcloud projects remove-iam-policy-binding "$MANAGEMENT_PROJECT_ID" \
  --member="$RECOVERY_MEMBER" --role="$RECOVERY_METADATA_ROLE" --condition=None
gcloud billing accounts remove-iam-policy-binding "$BILLING_ACCOUNT_ID" \
  --member="$RECOVERY_MEMBER" --role=roles/billing.user --condition=None
gcloud billing accounts remove-iam-policy-binding "$BILLING_ACCOUNT_ID" \
  --member="$RECOVERY_MEMBER" --role=roles/billing.costsManager --condition=None

if [[ -n "$FOLDER_ID" ]]; then
  gcloud resource-manager folders remove-iam-policy-binding "$FOLDER_ID" \
    --member="$RECOVERY_MEMBER" --role=roles/resourcemanager.projectCreator --condition=None
elif [[ -n "$ORGANIZATION_ID" ]]; then
  gcloud organizations remove-iam-policy-binding "$ORGANIZATION_ID" \
    --member="$RECOVERY_MEMBER" --role=roles/resourcemanager.projectCreator --condition=None
else
  gcloud projects remove-iam-policy-binding "$REPLACEMENT_PROJECT_ID" \
    --member="$RECOVERY_MEMBER" --role=roles/owner --condition=None
fi
```

Verify no temporary role remains. Query only the exact member; do not dump full policies into an
incident chat:

```bash
gcloud projects get-iam-policy "$MANAGEMENT_PROJECT_ID" \
  --flatten='bindings[].members' --filter="bindings.members=${RECOVERY_MEMBER}" \
  --format='table(bindings.role)'
gcloud billing accounts get-iam-policy "$BILLING_ACCOUNT_ID" \
  --flatten='bindings[].members' --filter="bindings.members=${RECOVERY_MEMBER}" \
  --format='table(bindings.role)'
```

Expected management rows are only the standing recovery roles created by bootstrap; the custom
metadata role is absent. No `billing.user`, `billing.costsManager`, parent Project Creator, or Owner
row remains.

## 5. Restore exact data and deploy the selected receipt

```bash
CONFIRM="RESTORE ${REPLACEMENT_PROJECT_ID}"
gh workflow run recovery.yaml --repo "$REPOSITORY" --ref master \
  -f operation=restore-data \
  -f replacement_project_id="$REPLACEMENT_PROJECT_ID" \
  -f target_receipt="$TARGET_RECEIPT" \
  -f json_keys_attempt="$JSON_KEYS_ATTEMPT" \
  -f authentication_attempt="$AUTHENTICATION_ATTEMPT" \
  -f lost_write_window="$LOST_WRITE_WINDOW" \
  -f confirm="$CONFIRM"
```

Approve `production-recovery` and watch the run. It verifies the attempts, quota grants, and receipt
secret versions; copies receipt-owned images read-only from production into the replacement registry;
creates only recovery jobs; starts the private database host; restores JSON Keys and Authentication
into empty targets; then creates both internal services. Repeating the same exact recovery jobs
reuses a durable successful execution rather than applying the archive twice.

## 6. Verify functionality from the private replacement network

First verify control-plane boundaries:

```bash
gcloud run services describe agora-json-keys \
  --project="$REPLACEMENT_PROJECT_ID" --region="$REGION" \
  --format='yaml(metadata.name,metadata.annotations,status.conditions,status.traffic)'
RECOVERY_AUTH_URL="$(gcloud run services describe agora-authentication \
  --project="$REPLACEMENT_PROJECT_ID" --region="$REGION" --format='value(status.url)')"
gcloud run services describe agora-authentication \
  --project="$REPLACEMENT_PROJECT_ID" --region="$REGION" \
  --format='yaml(metadata.name,metadata.annotations,status.conditions,status.traffic)'
gcloud scheduler jobs list --project="$REPLACEMENT_PROJECT_ID" --location="$REGION"
```

Expected: both services are Ready with internal-only ingress, no public Invoker bypass, and no
scheduler. The Authentication initializer job is absent.

Use the database VM as the already-existing private probe—no bastion, probe service, NAT, or proxy is
added. Connect through IAP as a configured database operator:

```bash
DATABASE_INSTANCE_URI="$(gcloud compute instance-groups managed list-instances agora-database \
  --project="$REPLACEMENT_PROJECT_ID" --zone="$DATABASE_ZONE" \
  --format='value(instance)' --limit=1)"
DATABASE_INSTANCE_NAME="${DATABASE_INSTANCE_URI##*/}"
gcloud compute ssh "$DATABASE_INSTANCE_NAME" \
  --project="$REPLACEMENT_PROJECT_ID" --zone="$DATABASE_ZONE" \
  --tunnel-through-iap
```

Inside that private COS session, paste the non-secret `RECOVERY_AUTH_URL`, request an identity token
from the VM metadata server, and require all three dependency probes to be up:

```bash
read -r -p 'Internal Authentication service URL: ' RECOVERY_AUTH_URL
[[ "$RECOVERY_AUTH_URL" =~ ^https://[a-z0-9.-]+\.run\.app$ ]]
IDENTITY_TOKEN="$(curl --fail --silent \
  -H 'Metadata-Flavor: Google' \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${RECOVERY_AUTH_URL}&format=full")"
HEALTH="$(curl --fail --silent \
  -H "Authorization: Bearer ${IDENTITY_TOKEN}" \
  "${RECOVERY_AUTH_URL}/v2/healthcheck")"
test "$(printf '%s' "$HEALTH" | grep -o '"status":"up"' | wc -l)" -eq 3
unset IDENTITY_TOKEN HEALTH
printf 'Private recovery health passed.\n'
exit
```

Authentication's health probes its PostgreSQL database, TLS SMTP, and JSON Keys gRPC; JSON Keys'
Status call probes its own database. Thus one private request validates both restored data paths and
the required private gRPC route without making either service externally callable.

Finally list only the recovery receipt name and record measured RPO/RTO in the incident:

```bash
gcloud storage ls \
  "gs://${RECEIPT_BUCKET}/recovery/${REPLACEMENT_PROJECT_ID}/*.json"
```

Do not leave a drill project running. Destruction is a separately reviewed, deletion-labeled plan;
until that cleanup path is executed, disable public cutover, retain the receipt, and account for the
extra always-on database VM in the cost record.
