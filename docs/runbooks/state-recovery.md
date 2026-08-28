# Recover a prior OpenTofu state generation

> Incident only: this is not part of a first run or ordinary rollback. Use it only for a corrupt,
> overwritten, or provably incorrect live state object.

Use this runbook only when the live state object is corrupt, accidentally overwritten, or known to
describe the wrong infrastructure generation. Ordinary infrastructure rollback uses a prior release
receipt and OpenTofu apply; it does not rewrite state. State recovery changes OpenTofu's record of
ownership and therefore requires a declared incident plus an independent maintainer's approval. The
clean-room workflow deliberately does not rewrite a live state object; this exceptional
generation-copy procedure remains a human operation.

The state bucket uses GCS Object Versioning, seven-day soft delete, protected managed folders, and
OpenTofu locking. Recovery copies a named noncurrent generation over the live object with an
`if-generation-match` precondition. The overwritten live generation remains noncurrent, so the
recovery itself can be rolled back. See [GCS versioned objects](https://cloud.google.com/storage/docs/using-versioned-objects),
[request preconditions](https://cloud.google.com/storage/docs/request-preconditions), and the
[OpenTofu GCS backend](https://opentofu.org/docs/language/settings/backends/gcs/).

Never download or print state in a shared terminal, GitHub artifact, issue, chat, or CI log. State can
contain sensitive infrastructure attributes even though this bootstrap deliberately excludes secret
payload versions.

## Preconditions

- Declare an incident/change record with the affected root, reason, last known good Git commit, and
  expected state lineage/serial if known.
- Pause every foundation, release, drift, and recovery workflow. State locking prevents concurrent
  writers but is not a substitute for an operator freeze.
- Use a declared human operator. The keyless recovery identity is bound to its exact GitHub workflow
  and cannot be impersonated from an operator shell.
- Work in a private Bash or Zsh session with tracing disabled and `umask 077`.
- Do not recover while a `.tflock` object exists. Identify and stop the owning operation first; never
  delete a lock merely because it is old.
- Recover only `bootstrap`, `foundation`, or `release`. Any other prefix is outside the root allowlist.

## 1. Freeze writers and select one state object

```bash
set -euo pipefail
set +x
umask 077

gh run list \
  --repo a-novel/infra \
  --status in_progress \
  --json databaseId,workflowName,headSha,status,url
gh run list \
  --repo a-novel/infra \
  --status queued \
  --json databaseId,workflowName,headSha,status,url
```

Expected safe result: both arrays are empty. If not, cancel or let the named runs finish and repeat;
record every cancellation in the incident.

Read the non-secret bucket variable and select one allowed root:

```bash
MANAGEMENT_PROJECT_ID="$(gh variable get GCP_MANAGEMENT_PROJECT_ID --repo a-novel/infra)"
STATE_BUCKET="$(gh variable get GCP_STATE_BUCKET --repo a-novel/infra)"

test -n "${MANAGEMENT_PROJECT_ID}"
test -n "${STATE_BUCKET}"

STATE_ROOT="$(./ops/prompt.sh 'State root (bootstrap, foundation, or release): ')"
case "${STATE_ROOT}" in
  bootstrap|foundation|release) ;;
  *) printf 'Refusing unknown state root.\n' >&2; false ;;
esac

STATE_OBJECT="gs://${STATE_BUCKET}/${STATE_ROOT}/default.tfstate"
LOCK_OBJECT="gs://${STATE_BUCKET}/${STATE_ROOT}/default.tflock"

assert_state_unlocked() {
  local root_objects

  # Listing the parent keeps authorization and network failures fatal. Testing
  # the lock URI directly would make those failures look like an absent lock.
  root_objects="$(gcloud storage ls "gs://${STATE_BUCKET}/${STATE_ROOT}/")"
  if grep -Fqx -- "${LOCK_OBJECT}" <<<"${root_objects}"; then
    printf 'Stop: %s is locked; identify the owning OpenTofu operation.\n' "${STATE_ROOT}" >&2
    false
  fi
}
```

Check for a live lock without printing its content:

```bash
assert_state_unlocked
```

Expected safe result: no output. If locked, use audit metadata to find the principal and operation;
do not run `gcloud storage rm` on the lock.

## 2. List generations and select a candidate

```bash
gcloud storage ls \
  --all-versions \
  --long \
  "${STATE_OBJECT}"
```

Expected safe result: one or more lines ending in `default.tfstate#<generation>` with size and
timestamps. Generation numbers, sizes, and dates are safe metadata. If there is only one generation,
stop: there is no older version to recover.

Copy the candidate generation number exactly, then validate that both candidate and live generations
are numeric and different:

```bash
CANDIDATE_GENERATION="$(./ops/prompt.sh 'Candidate generation to inspect: ')"
[[ "${CANDIDATE_GENERATION}" =~ ^[0-9]+$ ]]

LIVE_GENERATION="$(gcloud storage objects describe "${STATE_OBJECT}" --format='value(generation)')"
[[ "${LIVE_GENERATION}" =~ ^[0-9]+$ ]]
test "${CANDIDATE_GENERATION}" != "${LIVE_GENERATION}"

printf 'Candidate generation: %s\nLive generation: %s\n' \
  "${CANDIDATE_GENERATION}" \
  "${LIVE_GENERATION}"
```

Do not infer “latest good” from generation order alone. Match the candidate timestamp to the incident,
deployment receipt, Git commit, and audit trail.

## 3. Inspect the candidate without exposing values

Create a unique private directory and download the candidate and current live state for comparison
and emergency rollback. Neither file may leave this directory.

```bash
RECOVERY_TEMP_DIR="$(mktemp -d)"
CANDIDATE_STATE="${RECOVERY_TEMP_DIR}/candidate.tfstate"
ORIGINAL_LIVE_STATE="${RECOVERY_TEMP_DIR}/original-live.tfstate"

gcloud storage cp \
  "${STATE_OBJECT}#${CANDIDATE_GENERATION}" \
  "${CANDIDATE_STATE}" \
  --quiet
gcloud storage cp \
  "${STATE_OBJECT}#${LIVE_GENERATION}" \
  "${ORIGINAL_LIVE_STATE}" \
  --quiet

chmod 600 "${CANDIDATE_STATE}" "${ORIGINAL_LIVE_STATE}"
```

Inspect only lineage, serial, format version, and resource count:

```bash
for state_file in "${CANDIDATE_STATE}" "${ORIGINAL_LIVE_STATE}"; do
  jq -e '{
    version,
    terraform_version,
    serial,
    lineage,
    resource_count: (.resources | length)
  }' "${state_file}"
done

tofu state list -state="${CANDIDATE_STATE}"
sha256sum "${CANDIDATE_STATE}" "${ORIGINAL_LIVE_STATE}"
```

Expected safe result: valid JSON state, a non-empty lineage, numeric serials, plausible resource
addresses for the selected root, and two hashes for the private incident record. The candidate should
normally share the live lineage and have an earlier serial. A different lineage indicates a different
state history; stop unless the incident explicitly concerns a lineage replacement.

Never use `jq .`, `tofu show`, `tofu state pull`, or `gcloud storage cat` here: those commands can
print attribute values.

## 4. Restore with an optimistic-concurrency precondition

Recheck that no workflow or lock appeared since inspection:

```bash
# Assign before testing so a failed GitHub query aborts instead of looking like
# an empty run list.
IN_PROGRESS_RUN_IDS="$(gh run list --repo a-novel/infra --status in_progress --json databaseId --jq '.[].databaseId')"
QUEUED_RUN_IDS="$(gh run list --repo a-novel/infra --status queued --json databaseId --jq '.[].databaseId')"
test -z "${IN_PROGRESS_RUN_IDS}"
test -z "${QUEUED_RUN_IDS}"

assert_state_unlocked

CURRENT_GENERATION="$(gcloud storage objects describe "${STATE_OBJECT}" --format='value(generation)')"
test "${CURRENT_GENERATION}" = "${LIVE_GENERATION}"
```

The final equality check is the human-readable precondition; Cloud Storage enforces it atomically in
the copy itself:

```bash
RESTORE_CONFIRMATION="$(./ops/prompt.sh "Type ${STATE_ROOT}/${CANDIDATE_GENERATION} to restore: ")"
test "${RESTORE_CONFIRMATION}" = "${STATE_ROOT}/${CANDIDATE_GENERATION}"

gcloud storage cp \
  "${STATE_OBJECT}#${CANDIDATE_GENERATION}" \
  "${STATE_OBJECT}" \
  --if-generation-match="${LIVE_GENERATION}" \
  --quiet

RESTORED_GENERATION="$(gcloud storage objects describe "${STATE_OBJECT}" --format='value(generation)')"
[[ "${RESTORED_GENERATION}" =~ ^[0-9]+$ ]]
test "${RESTORED_GENERATION}" != "${LIVE_GENERATION}"
printf 'Restored live generation: %s\n' "${RESTORED_GENERATION}"
```

Expected safe result: a new numeric live generation. A `412` precondition failure means another writer
changed the object; the restore did not happen. Return to the freeze step and investigate—do not retry
with the new generation automatically.

## 5. Validate reconciliation before any apply

State restoration does not change cloud resources. Check out the exact Git commit associated with
the candidate in a separate worktree, initialize only the selected backend, and make a saved plan.
Do not apply it during this runbook.

```bash
CANDIDATE_GIT_SHA="$(./ops/prompt.sh 'Candidate state Git commit SHA: ')"
git cat-file -e "${CANDIDATE_GIT_SHA}^{commit}"

RECOVERY_CHECKOUT="${RECOVERY_TEMP_DIR}/checkout"
git worktree add --detach "${RECOVERY_CHECKOUT}" "${CANDIDATE_GIT_SHA}"

case "${STATE_ROOT}" in
  bootstrap) ROOT_DIRECTORY='bootstrap' ;;
  foundation) ROOT_DIRECTORY='environments/production/foundation' ;;
  release) ROOT_DIRECTORY='environments/production/release' ;;
esac

export TF_DATA_DIR="${RECOVERY_TEMP_DIR}/tofu-data"
tofu -chdir="${RECOVERY_CHECKOUT}/${ROOT_DIRECTORY}" init \
  -reconfigure \
  -input=false \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="prefix=${STATE_ROOT}"
```

Supply only the root's documented non-secret variables and its normal secret references. For the
currently deployed bootstrap root:

```bash
if [ "${STATE_ROOT}" = 'bootstrap' ]; then
  OPERATOR_EMAIL="$(gcloud config get-value account 2>/dev/null)"
  export TF_VAR_management_project_id="${MANAGEMENT_PROJECT_ID}"
  export TF_VAR_operator_principals="[\"user:${OPERATOR_EMAIL}\"]"
fi
```

For foundation or release, retrieve the exact current protected configuration object documented by
the deployment runbook into this private temporary directory; do not reconstruct values from memory.
Then generate a private plan and sanitize it:

```bash
RECOVERY_PLAN="${RECOVERY_TEMP_DIR}/recovery.tfplan"
RECOVERY_PLAN_JSON="${RECOVERY_TEMP_DIR}/recovery.json"

tofu -chdir="${RECOVERY_CHECKOUT}/${ROOT_DIRECTORY}" plan \
  -input=false \
  -out="${RECOVERY_PLAN}" >/dev/null
tofu -chdir="${RECOVERY_CHECKOUT}/${ROOT_DIRECTORY}" show \
  -json "${RECOVERY_PLAN}" >"${RECOVERY_PLAN_JSON}"
"${RECOVERY_CHECKOUT}/ops/plan-summary.sh" "${STATE_ROOT}" "${RECOVERY_PLAN_JSON}"
```

Expected safe result depends on the incident:

- if only the live state object was corrupt, the summary should have no changes;
- if state was intentionally rewound while cloud resources remained newer, the summary should show
  the expected reconciliation actions by type and count;
- any managed-resource deletion, replacement, or state-forget action exits with status `3` and requires a
  separate reviewed recovery decision.

Never apply this plan as part of state restoration. Attach only the sanitized summary and private
hashes to the incident; route any resource reconciliation through the protected foundation or release
workflow using a newly reviewed plan.

## 6. Roll back a mistaken state restore

The generation that was live before recovery remains available as `LIVE_GENERATION`. If validation
shows the candidate was wrong, restore that original generation over the recovery generation with a
second atomic precondition:

```bash
IN_PROGRESS_RUN_IDS="$(gh run list --repo a-novel/infra --status in_progress --json databaseId --jq '.[].databaseId')"
QUEUED_RUN_IDS="$(gh run list --repo a-novel/infra --status queued --json databaseId --jq '.[].databaseId')"
test -z "${IN_PROGRESS_RUN_IDS}"
test -z "${QUEUED_RUN_IDS}"

assert_state_unlocked

CURRENT_GENERATION="$(gcloud storage objects describe "${STATE_OBJECT}" --format='value(generation)')"
test "${CURRENT_GENERATION}" = "${RESTORED_GENERATION}"

ROLLBACK_CONFIRMATION="$(./ops/prompt.sh "Type rollback/${LIVE_GENERATION} to restore the original live state: ")"
test "${ROLLBACK_CONFIRMATION}" = "rollback/${LIVE_GENERATION}"

gcloud storage cp \
  "${STATE_OBJECT}#${LIVE_GENERATION}" \
  "${STATE_OBJECT}" \
  --if-generation-match="${RESTORED_GENERATION}" \
  --quiet

ROLLBACK_GENERATION="$(gcloud storage objects describe "${STATE_OBJECT}" --format='value(generation)')"
printf 'Original state restored as new live generation: %s\n' "${ROLLBACK_GENERATION}"
```

Expected safe result: another new live generation. Repeat the private validation plan from the
original Git commit. Do not delete the mistaken or original generations; lifecycle protection keeps
the recovery evidence.

## 7. Audit and clean up

Query metadata for the exact object and recovery time:

```bash
gcloud logging read \
  'resource.type="gcs_bucket" AND resource.labels.bucket_name="'"${STATE_BUCKET}"'" AND protoPayload.resourceName:"/'"${STATE_ROOT}"'/default.tfstate"' \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --limit=30 \
  --format='table(timestamp,protoPayload.methodName,protoPayload.authenticationInfo.principalEmail)'
```

Record candidate, former live, restored, and optional rollback generation numbers; hashes; operator;
approval; commit; plan-summary result; and timestamps. These are recovery metadata, not state content.

Remove the detached worktree before deleting the unique temporary directory:

```bash
git worktree remove "${RECOVERY_CHECKOUT}"
rm -rf -- "${RECOVERY_TEMP_DIR}"

unset TF_DATA_DIR TF_VAR_management_project_id TF_VAR_operator_principals
unset MANAGEMENT_PROJECT_ID STATE_BUCKET STATE_ROOT STATE_OBJECT LOCK_OBJECT ROOT_DIRECTORY
unset CANDIDATE_GENERATION LIVE_GENERATION CURRENT_GENERATION RESTORED_GENERATION ROLLBACK_GENERATION
unset CANDIDATE_STATE ORIGINAL_LIVE_STATE CANDIDATE_GIT_SHA RECOVERY_CHECKOUT RECOVERY_TEMP_DIR
unset RECOVERY_PLAN RECOVERY_PLAN_JSON RESTORE_CONFIRMATION ROLLBACK_CONFIRMATION OPERATOR_EMAIL
unset IN_PROGRESS_RUN_IDS QUEUED_RUN_IDS
unset -f assert_state_unlocked
```

This permanently deletes only the private temporary copies and detached worktree. GCS generations,
audit logs, cloud resources, and Git history remain. Unfreeze workflows only after the incident owner
accepts the validation result and any separate reconciliation plan has completed.
