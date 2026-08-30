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

## Operator context

Load the published project coordinates. Then run later blocks in the existing configured zsh
session, replace `STATE_ROOT` with `bootstrap`, `foundation`, or `release`, and paste the context
block once:

```sh
. ./.envrc
./ops/verify-operator-env.sh --github
```

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
umask 077

REPOSITORY='a-novel/infra'
STATE_ROOT=''

MANAGEMENT_PROJECT_ID="$INFRA_MANAGEMENT_PROJECT_ID"
STATE_BUCKET="$(gh variable get GCP_STATE_BUCKET --repo "$REPOSITORY")"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

## Preconditions

- Declare an incident/change record with the affected root, reason, last known good Git commit, and
  expected state lineage/serial if known.
- Pause every foundation, release, drift, and recovery workflow. State locking prevents concurrent
  writers but is not a substitute for an operator freeze.
- Use a declared human operator. The keyless recovery identity is bound to its exact GitHub workflow
  and cannot be impersonated from an operator shell.
- Work in a private zsh session with tracing disabled and `umask 077`.
- Do not recover while a `.tflock` object exists. Identify and stop the owning operation first; never
  delete a lock merely because it is old.
- Recover only `bootstrap`, `foundation`, or `release`. Any other prefix is outside the root allowlist.

## 1. Freeze writers and select one state object

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gh api "repos/${REPOSITORY}/actions/runs?branch=master&per_page=100" --jq '[
  .workflow_runs[]
  | select(.status != "completed")
  | select(
      .path == ".github/workflows/drift.yaml" or
      .path == ".github/workflows/foundation.yaml" or
      .path == ".github/workflows/recovery.yaml" or
      .path == ".github/workflows/release.yaml"
    )
  | {id, name, display_title, head_sha, status, html_url}
]'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: `[]`. This includes queued, requested, waiting-for-approval, pending, and
in-progress runs. If it is non-empty, cancel or let the named runs finish and repeat; record every
cancellation in the incident.

Validate the selected bucket and root, then derive the two object names:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
test -n "${MANAGEMENT_PROJECT_ID}"
test -n "${STATE_BUCKET}"

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
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Check for a live lock without printing its content:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
assert_state_unlocked
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: no output. If locked, use audit metadata to find the principal and operation;
do not run `gcloud storage rm` on the lock.

## 2. List generations and select a candidate

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud storage ls \
  --all-versions \
  --long \
  "${STATE_OBJECT}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: one or more lines ending in `default.tfstate#<generation>` with size and
timestamps. Generation numbers, sizes, and dates are safe metadata. If there is only one generation,
stop: there is no older version to recover.

Copy the candidate generation number exactly, then validate that both candidate and live generations
are numeric and different:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
CANDIDATE_GENERATION=''
[[ "${CANDIDATE_GENERATION}" =~ ^[0-9]+$ ]]

LIVE_GENERATION="$(gcloud storage objects describe "${STATE_OBJECT}" --format='value(generation)')"
[[ "${LIVE_GENERATION}" =~ ^[0-9]+$ ]]
test "${CANDIDATE_GENERATION}" != "${LIVE_GENERATION}"

printf 'Candidate generation: %s\nLive generation: %s\n' \
  "${CANDIDATE_GENERATION}" \
  "${LIVE_GENERATION}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Do not infer “latest good” from generation order alone. Match the candidate timestamp to the incident,
deployment receipt, Git commit, and audit trail.

## 3. Inspect the candidate without exposing values

Create a unique private directory and download the candidate and current live state for comparison
and emergency rollback. Neither file may leave this directory.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
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
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Inspect only lineage, serial, format version, and resource count:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
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
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: valid JSON state, a non-empty lineage, numeric serials, plausible resource
addresses for the selected root, and two hashes for the private incident record. The candidate should
normally share the live lineage and have an earlier serial. A different lineage indicates a different
state history; stop unless the incident explicitly concerns a lineage replacement.

Never use `jq .`, `tofu show`, `tofu state pull`, or `gcloud storage cat` here: those commands can
print attribute values.

## 4. Restore with an optimistic-concurrency precondition

Recheck that no workflow or lock appeared since inspection:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
# Assign before testing so a failed GitHub query aborts instead of looking like
# an empty run list.
ACTIVE_RUN_IDS="$(gh api "repos/${REPOSITORY}/actions/runs?branch=master&per_page=100" --jq '
  .workflow_runs[]
  | select(.status != "completed")
  | select(
      .path == ".github/workflows/drift.yaml" or
      .path == ".github/workflows/foundation.yaml" or
      .path == ".github/workflows/recovery.yaml" or
      .path == ".github/workflows/release.yaml"
    )
  | .id
')"
test -z "${ACTIVE_RUN_IDS}"

assert_state_unlocked

CURRENT_GENERATION="$(gcloud storage objects describe "${STATE_OBJECT}" --format='value(generation)')"
test "${CURRENT_GENERATION}" = "${LIVE_GENERATION}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

The final equality check is the human-readable precondition; Cloud Storage enforces it atomically in
the copy itself:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
printf 'Type %s/%s to restore: ' "$STATE_ROOT" "$CANDIDATE_GENERATION"
IFS= read -r RESTORE_CONFIRMATION
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
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: a new numeric live generation. A `412` precondition failure means another writer
changed the object; the restore did not happen. Return to the freeze step and investigate—do not retry
with the new generation automatically.

## 5. Validate reconciliation before any apply

State restoration does not change cloud resources. Check out the exact Git commit associated with
the candidate in a separate worktree, initialize only the selected backend, and make a saved plan.
Do not apply it during this runbook.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
CANDIDATE_GIT_SHA=''
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
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Supply only the root's documented non-secret variables and its normal secret references. For the
currently deployed bootstrap root:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
if [ "${STATE_ROOT}" = 'bootstrap' ]; then
  OPERATOR_EMAIL="$(gcloud config get-value account 2>/dev/null)"
  export TF_VAR_management_project_id="${MANAGEMENT_PROJECT_ID}"
  export TF_VAR_operator_principals="[\"user:${OPERATOR_EMAIL}\"]"
fi
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

For foundation or release, retrieve the exact current protected configuration object documented by
the deployment runbook into this private temporary directory; do not reconstruct values from memory.
Then generate a private plan and sanitize it:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
RECOVERY_PLAN="${RECOVERY_TEMP_DIR}/recovery.tfplan"
RECOVERY_PLAN_JSON="${RECOVERY_TEMP_DIR}/recovery.json"

tofu -chdir="${RECOVERY_CHECKOUT}/${ROOT_DIRECTORY}" plan \
  -input=false \
  -out="${RECOVERY_PLAN}" >/dev/null
tofu -chdir="${RECOVERY_CHECKOUT}/${ROOT_DIRECTORY}" show \
  -json "${RECOVERY_PLAN}" >"${RECOVERY_PLAN_JSON}"
"${RECOVERY_CHECKOUT}/ops/plan-summary.sh" "${STATE_ROOT}" "${RECOVERY_PLAN_JSON}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
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

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
ACTIVE_RUN_IDS="$(gh api "repos/${REPOSITORY}/actions/runs?branch=master&per_page=100" --jq '
  .workflow_runs[]
  | select(.status != "completed")
  | select(
      .path == ".github/workflows/drift.yaml" or
      .path == ".github/workflows/foundation.yaml" or
      .path == ".github/workflows/recovery.yaml" or
      .path == ".github/workflows/release.yaml"
    )
  | .id
')"
test -z "${ACTIVE_RUN_IDS}"

assert_state_unlocked

CURRENT_GENERATION="$(gcloud storage objects describe "${STATE_OBJECT}" --format='value(generation)')"
test "${CURRENT_GENERATION}" = "${RESTORED_GENERATION}"

printf 'Type rollback/%s to restore the original live state: ' "$LIVE_GENERATION"
IFS= read -r ROLLBACK_CONFIRMATION
test "${ROLLBACK_CONFIRMATION}" = "rollback/${LIVE_GENERATION}"

gcloud storage cp \
  "${STATE_OBJECT}#${LIVE_GENERATION}" \
  "${STATE_OBJECT}" \
  --if-generation-match="${RESTORED_GENERATION}" \
  --quiet

ROLLBACK_GENERATION="$(gcloud storage objects describe "${STATE_OBJECT}" --format='value(generation)')"
printf 'Original state restored as new live generation: %s\n' "${ROLLBACK_GENERATION}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: another new live generation. Repeat the private validation plan from the
original Git commit. Do not delete the mistaken or original generations; lifecycle protection keeps
the recovery evidence.

## 7. Audit and clean up

Query metadata for the exact object and recovery time:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud logging read \
  'resource.type="gcs_bucket" AND resource.labels.bucket_name="'"${STATE_BUCKET}"'" AND protoPayload.resourceName:"/'"${STATE_ROOT}"'/default.tfstate"' \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --limit=30 \
  --format='table(timestamp,protoPayload.methodName,protoPayload.authenticationInfo.principalEmail)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Record candidate, former live, restored, and optional rollback generation numbers; hashes; operator;
approval; commit; plan-summary result; and timestamps. These are recovery metadata, not state content.

Remove the detached worktree before deleting the unique temporary directory:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
git worktree remove "${RECOVERY_CHECKOUT}"
rm -rf -- "${RECOVERY_TEMP_DIR}"

unset TF_DATA_DIR TF_VAR_management_project_id TF_VAR_operator_principals
unset MANAGEMENT_PROJECT_ID STATE_BUCKET STATE_ROOT STATE_OBJECT LOCK_OBJECT ROOT_DIRECTORY
unset CANDIDATE_GENERATION LIVE_GENERATION CURRENT_GENERATION RESTORED_GENERATION ROLLBACK_GENERATION
unset CANDIDATE_STATE ORIGINAL_LIVE_STATE CANDIDATE_GIT_SHA RECOVERY_CHECKOUT RECOVERY_TEMP_DIR
unset RECOVERY_PLAN RECOVERY_PLAN_JSON RESTORE_CONFIRMATION ROLLBACK_CONFIRMATION OPERATOR_EMAIL
unset ACTIVE_RUN_IDS
unset -f assert_state_unlocked
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

This permanently deletes only the private temporary copies and detached worktree. GCS generations,
audit logs, cloud resources, and Git history remain. Unfreeze workflows only after the incident owner
accepts the validation result and any separate reconciliation plan has completed.
