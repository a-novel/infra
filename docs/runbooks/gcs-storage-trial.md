# Isolated GCS storage trial

This is a **human-only** evaluation for [the backup comparison](https://github.com/a-novel/infra/issues/190).
It uses synthetic objects to test mutable-catalog custody before running pgBackRest against GCS.
Merging this guide authorizes no cloud operations. Production buckets, backups, schedules and IAM stay unchanged.
The [27 September result](../../proofs/gcs-storage/result-20260927.md) records the completed synthetic
trial and its outstanding cleanup; every new run still needs its own scope approval.

## 1. Approve the disposable scope

Record the exact commit, existing disposable project, selected service, operator, cleanup owner and
retention duration in the issue before proceeding. Approve 300–3600 seconds of **unlocked** retention
and seven days of soft delete; all copies remain billable during that window. Use an empty project
named `a-novel-gcs-proof-<6–12 lowercase letters or digits>`, with billing and the Storage, IAM and
IAM Credentials APIs already enabled. A name check prevents mistakes; it does not establish ownership.

Review inherited IAM for both new identities: neither may inherit storage, project-administration or
impersonation privileges. Provisioning needs a separately approved operator; the trial identities get
no project-wide binding. Authorize the operator to impersonate only these two accounts with expiring
account-level grants. Do not create keys or reuse a production principal. This root creates no such
operator grants, projects, APIs, compute resources or backup jobs.

Start from the approved checkout, using a private local directory for state and evidence. Set
`TF_VAR_project_id`, `TF_VAR_service`, and `TF_VAR_retention_seconds` to the approved values first.
Run each block separately from zsh or Bash; stop on any unexpected result. Keep the same shell session.
Use the Google Cloud CLI version pinned in the repository's workflows and record its version.

```sh
umask 077
TRIAL_DIR="$(mktemp -d "${HOME:?}/agora-gcs-proof.XXXXXXXX")" &&
export TRIAL_DIR &&
export TF_DATA_DIR="${TRIAL_DIR:?}/provider" &&
export TRIAL_PROJECT="${TF_VAR_project_id:?}" &&
export TRIAL_BUCKET="${TRIAL_PROJECT:?}-${TF_VAR_service:?}" &&
export TRIAL_PEER="${TRIAL_PROJECT:?}-peer" &&
export TRIAL_WRITER="gcs-proof-writer@${TRIAL_PROJECT:?}.iam.gserviceaccount.com" &&
export TRIAL_RECOVERY="gcs-proof-recovery@${TRIAL_PROJECT:?}.iam.gserviceaccount.com"
```

After the scope and provisioning approval, plan from `proofs/gcs-storage`. Review that it creates
exactly two new buckets, two identities, two custom roles and two selected-bucket grants, with no
imports, replacements or deletions. Only the human applies the saved plan. Preserve the local state
securely through cleanup; it must never be committed or uploaded as a public artifact.

```sh
(
set -euo pipefail
tofu -chdir=proofs/gcs-storage init -backend=false -input=false -lockfile=readonly
tofu -chdir=proofs/gcs-storage plan -input=false -state="${TRIAL_DIR:?}/trial.tfstate" -out="${TRIAL_DIR:?}/trial.tfplan"
tofu -chdir=proofs/gcs-storage show "${TRIAL_DIR:?}/trial.tfplan"
)
```

```sh
tofu -chdir=proofs/gcs-storage apply -state="${TRIAL_DIR:?}/trial.tfstate" "${TRIAL_DIR:?}/trial.tfplan"
```

## 2. Inspect custody and exercise denied access

Compare the created outputs with the independently approved coordinates before any object write.
The saved IAM policy includes its etag; the later negative test must use that exact policy.

```sh
(
set -euo pipefail
tofu -chdir=proofs/gcs-storage output -state="${TRIAL_DIR:?}/trial.tfstate" -json trial |
  jq -e --arg project "${TRIAL_PROJECT:?}" --arg service "${TF_VAR_service:?}" \
    --argjson retention "${TF_VAR_retention_seconds:?}" '
  . == {project_id: $project, service: $service, bucket: ($project + "-" + $service),
    peer_bucket: ($project + "-peer"), retention_seconds: $retention,
    writer: ("gcs-proof-writer@" + $project + ".iam.gserviceaccount.com"),
    recovery: ("gcs-proof-recovery@" + $project + ".iam.gserviceaccount.com")}'
gcloud storage buckets describe "gs://${TRIAL_BUCKET:?}" --project="${TRIAL_PROJECT:?}" \
  --format='yaml(name,location,versioning,retention_policy,soft_delete_policy,lifecycle_config,iam_config)'
gcloud storage buckets get-iam-policy "gs://${TRIAL_BUCKET:?}" --project="${TRIAL_PROJECT:?}" \
  --format=json >"${TRIAL_DIR:?}/bucket-iam.json"
gcloud storage buckets describe "gs://${TRIAL_PEER:?}" --project="${TRIAL_PROJECT:?}" --format='value(name)'
)
```

Confirm private uniform access, versioning, the approved unlocked retention, seven-day soft delete,
no lifecycle rules, and only the two intended object-role grants. Inspect inherited permissions too.
Obtain the approved, expiring impersonation grants now. Record the operator and expiry in the evidence.
Allow at least 30 seconds for versioning propagation before writing or replacing objects; wait for
IAM propagation too. Do not expand a role to work around a propagation delay.
Preserve the private state/evidence directory across sessions and reboots; cleanup extends beyond the
soft-delete window. Confirm both identities can list their selected bucket before testing peer denial.

Run these **negative checks individually**, as the writer. Each must return HTTP 403 identifying the
corresponding denied permission. Authentication, quota, missing-resource, retention, etag or syntax
errors are inconclusive. Stop if a command succeeds; inspect the disposable bucket and its policy
before continuing. Policy tests attempt the already configured values and the saved etag-bound policy.

```sh
(
set +x
set -euo pipefail
trial_token="$(gcloud auth print-access-token --project="${TRIAL_PROJECT:?}" \
  --impersonate-service-account="${TRIAL_WRITER:?}")"
case "$trial_token" in
  ''|*[^A-Za-z0-9._~+/=-]*) printf 'STOP: invalid access-token response.\n' >&2; exit 1 ;;
esac
builtin printf 'header = "Authorization: Bearer %s"\n' "$trial_token" |
  curl -q --config - --silent --show-error --fail-with-body \
    --connect-timeout 10 --max-time 60 --request POST --header 'Content-Type: text/plain' \
    --data-binary 'peer-denial-probe' --write-out '\nHTTP_STATUS=%{http_code}\n' \
    "https://storage.googleapis.com/upload/storage/v1/b/${TRIAL_PEER:?}/o?uploadType=media&name=probe&ifGenerationMatch=0"
)
```

This direct upload tests `storage.objects.create`; CLI copy may fail on its preliminary GET instead.
The token goes through standard input, not command arguments or output. The `[^...]` pattern also
avoids interactive zsh's `!` history expansion. Expected curl exit 22 with HTTP 403 is a negative pass
only when the response identifies the intended principal and denied create permission.

```sh
gcloud storage objects list "gs://${TRIAL_PEER:?}/**" \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_WRITER:?}"
```

Repeat the peer listing as the recovery identity and require the same permission denial. An empty
successful listing fails the isolation test even though the peer bucket contains no data.

```sh
gcloud storage buckets update "gs://${TRIAL_BUCKET:?}" --retention-period="${TF_VAR_retention_seconds:?}s" \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_WRITER:?}"
```

```sh
(
set -euo pipefail
trial_etag="$(jq -er '.etag | select(type == "string" and length > 0)' "${TRIAL_DIR:?}/bucket-iam.json")"
gcloud storage buckets set-iam-policy "gs://${TRIAL_BUCKET:?}" "${TRIAL_DIR:?}/bucket-iam.json" --etag="$trial_etag" \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_WRITER:?}"
)
```

## 3. Replace a retained catalog

Create a catalog and an older full-backup stand-in. These are tiny text fixtures, not pgBackRest files.
Create-only preconditions make a reused namespace fail. Save generation metadata immediately.

```sh
(
set -euo pipefail
printf 'catalog-v1\n' | gcloud storage cp - "gs://${TRIAL_BUCKET:?}/catalog" --if-generation-match=0 \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_WRITER:?}"
gcloud storage objects describe "gs://${TRIAL_BUCKET:?}/catalog" --raw --format=json \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_WRITER:?}" >"${TRIAL_DIR:?}/catalog-v1.json"
printf 'full-v1\n' | gcloud storage cp - "gs://${TRIAL_BUCKET:?}/full" --if-generation-match=0 \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_WRITER:?}"
gcloud storage objects describe "gs://${TRIAL_BUCKET:?}/full" --raw --format=json \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_WRITER:?}" >"${TRIAL_DIR:?}/full.json"
catalog_generation="$(jq -er '.generation' "${TRIAL_DIR:?}/catalog-v1.json")"
printf 'catalog-v2\n' | gcloud storage cp - "gs://${TRIAL_BUCKET:?}/catalog" --if-generation-match="$catalog_generation" \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_WRITER:?}"
gcloud storage objects list "gs://${TRIAL_BUCKET:?}/**" --raw --format=json \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_RECOVERY:?}" >"${TRIAL_DIR:?}/before-expiry.json"
test "$(gcloud storage cat "gs://${TRIAL_BUCKET:?}/catalog#${catalog_generation}" \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_RECOVERY:?}")" = 'catalog-v1'
)
```

Before the saved catalog generation's `retentionExpirationTime`, try deleting that exact generation.
Require HTTP 403 with `retentionPolicyNotMet`. If the time already passed, stop and repeat with a newly
approved empty namespace; a successful late delete cannot test retention. Save the response and UTC time.

```sh
(
set -euo pipefail
catalog_generation="$(jq -er '.generation' "${TRIAL_DIR:?}/catalog-v1.json")"
gcloud storage rm "gs://${TRIAL_BUCKET:?}/catalog#${catalog_generation}" \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_WRITER:?}"
)
```

## 4. Recover an aged dependency

Wait until **both** saved objects' `retentionExpirationTime` values are in the past. Keep the retention
policy unchanged. Create a fresh differential stand-in referencing the old full generation, then delete
the exact old full and catalog generations. This models a damaged dependency older than its protection
window, even though a recent backup still depends on it.

```sh
(
set -euo pipefail
full_generation="$(jq -er '.generation' "${TRIAL_DIR:?}/full.json")"
catalog_generation="$(jq -er '.generation' "${TRIAL_DIR:?}/catalog-v1.json")"
printf 'depends-on-full-generation=%s\n' "$full_generation" | gcloud storage cp - "gs://${TRIAL_BUCKET:?}/differential" \
  --if-generation-match=0 --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_WRITER:?}"
gcloud storage rm "gs://${TRIAL_BUCKET:?}/full#${full_generation}" "gs://${TRIAL_BUCKET:?}/catalog#${catalog_generation}" \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_WRITER:?}"
gcloud storage objects list "gs://${TRIAL_BUCKET:?}/**" --soft-deleted --exhaustive --raw --format=json \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_RECOVERY:?}" >"${TRIAL_DIR:?}/soft-deleted.json"
)
```

Confirm both saved generations appear with `softDeleteTime` and `hardDeleteTime`. Ordinary reads of
those generations must now fail (404, not IAM denial). Run this check individually for `full` and
`catalog`, substituting their saved generation; do not count a missing latest object alone as proof.

```sh
gcloud storage objects describe "gs://${TRIAL_BUCKET:?}/${TRIAL_OBJECT:?}#${TRIAL_GENERATION:?}" \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_RECOVERY:?}"
```

Restore the old full using the recovery identity. The writer cannot restore: repeat this command as
the writer first and require 403 for `storage.objects.restore`. Then use the recovery identity below.
There is no live full object, so recovery needs create/restore but no delete permission.

```sh
(
set -euo pipefail
full_generation="$(jq -er '.generation' "${TRIAL_DIR:?}/full.json")"
gcloud storage restore "gs://${TRIAL_BUCKET:?}/full#${full_generation}" --if-generation-match=0 --no-preserve-acl \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_RECOVERY:?}"
gcloud storage objects describe "gs://${TRIAL_BUCKET:?}/full" --raw --format=json \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_RECOVERY:?}" >"${TRIAL_DIR:?}/restored-full.json"
test "$(gcloud storage cat "gs://${TRIAL_BUCKET:?}/full" \
  --project="${TRIAL_PROJECT:?}" --impersonate-service-account="${TRIAL_RECOVERY:?}")" = 'full-v1'
jq -e --slurpfile original "${TRIAL_DIR:?}/full.json" '
  .generation != $original[0].generation and .crc32c == $original[0].crc32c and
  .size == $original[0].size' "${TRIAL_DIR:?}/restored-full.json"
)
```

Save the new generation, `timeCreated`, `updated`, checksums and native restore result. Google's
[restore API](https://docs.cloud.google.com/storage/docs/json_api/v1/objects/restore) creates a new
live copy. This recovers bytes; it does not re-create the original generation identity. A second
restore with `--if-generation-match=0` must fail with 412 and leave the recovered copy unchanged.

The remaining soft-deleted catalog is intentional: recovering a historical catalog while another
catalog is live is an additional operator decision. Before pgBackRest adoption, test its exact
[`--repo-target-time`](https://pgbackrest.org/configuration.html#section-repository/option-repo-target-time)
selection after native recovery. Its GCS backend filters version timestamps; restoring bytes alone
does not establish historical catalog/WAL selection or an intact recovery chain.

## 5. Record the result and clean up separately

Save one evidence record with the approved scope, effective IAM, each native result, generation
metadata, UTC times, checksum comparison and the reviewer. List both noncurrent/live and soft-deleted
objects; sum their raw `size` fields separately to expose retained bytes. Retain the billing/cost
review, including copies that outlive the trial. None of these tiny fixtures predicts production WAL cost.
Native object listing includes live and noncurrent generations by default; use a separate
`--soft-deleted --exhaustive` inventory for retained deleted copies, with the quoted `/**` pattern.

The acceptance decision is **storage semantics observed**, not production custody approval, a
pgBackRest integration pass or RPO/RTO evidence. CI validates HCL and command syntax only. Actual cloud
results, inherited IAM and time-dependent behavior require this separately approved human run.

Remove the exact temporary impersonation grants. After all live and noncurrent generations have
passed retention, review their inventory and approve generation-specific deletion. Wait for the
recorded soft-delete deadlines; do not shorten protection to accelerate cleanup. Preserve state until
a human-reviewed `tofu plan -destroy` / saved-plan apply removes only these trial resources. Buckets
have `force_destroy=false`; a nonempty bucket must block deletion. Verify cleanup and retained billing
with the named owner before deleting local evidence or state.

[Bucket Lock](https://docs.cloud.google.com/storage/docs/bucket-lock) is a separate acceptance gate:
locking is irreversible and creates a project lien. This trial provides no lock switch. A later
locked drill needs explicit lock approval, its own cleanup/lien plan, and proof that administrative
policy changes are denied. Before a production cutover, also prove full/differential/WAL restoration,
interrupted GCS writes, workload-identity loss and retained-reader compatibility using the published,
security-reviewed service images. Preserve current logical backup readers throughout that transition.
