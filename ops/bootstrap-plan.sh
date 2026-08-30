#!/bin/bash

# Creates or applies the one local bootstrap plan with durable commit custody.

set -euo pipefail
umask 077

usage() {
    printf 'Usage: %s <plan|apply> <management-project-id> <absolute-plan-file>\n' "$0" >&2
    exit 64
}

fail() {
    printf '%s\n' "$1" >&2
    exit "${2:-65}"
}

if [ "$#" -ne 3 ]; then
    usage
fi

ACTION="$1"
MANAGEMENT_PROJECT_ID="$2"
PLAN_FILE="$3"
case "$ACTION" in
    plan | apply) ;;
    *) usage ;;
esac
if ! [[ "$MANAGEMENT_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
    fail 'Invalid management project ID.' 64
fi
if [[ "$PLAN_FILE" != /* ]] || [[ "$PLAN_FILE" == */ ]]; then
    fail 'The private bootstrap plan path must be an absolute file path.' 64
fi
if [[ "$PLAN_FILE" =~ [[:cntrl:]] ]]; then
    fail 'The private bootstrap plan path contains control characters.' 64
fi
if [ -L "$PLAN_FILE" ] || [ -L "${PLAN_FILE}.metadata.json" ]; then
    fail 'Bootstrap plan custody refuses symbolic links.'
fi
if [ ! -d "$(dirname -- "$PLAN_FILE")" ]; then
    fail 'The private bootstrap plan directory does not exist.' 66
fi
PLAN_BASENAME="$(basename -- "$PLAN_FILE")"
if [ "$PLAN_BASENAME" = . ] || [ "$PLAN_BASENAME" = .. ]; then
    fail 'The private bootstrap plan path must name a file.' 64
fi
PLAN_DIRECTORY="$(cd -- "$(dirname -- "$PLAN_FILE")" && pwd -P)"
PLAN_FILE="${PLAN_DIRECTORY}/${PLAN_BASENAME}"

for command_name in gcloud gh git jq sha256sum; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "$command_name is required for local bootstrap plan custody." 69
    fi
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
METADATA_FILE="${PLAN_FILE}.metadata.json"
REPOSITORY='a-novel/infra'

case "$PLAN_FILE" in
    "${REPOSITORY_ROOT}" | "${REPOSITORY_ROOT}"/*)
        fail 'Private plan files must stay outside the repository.'
        ;;
esac

if [ "$(git -C "$REPOSITORY_ROOT" branch --show-current)" != master ] ||
    [ -n "$(git -C "$REPOSITORY_ROOT" status --porcelain)" ]; then
    fail 'Local bootstrap plan custody requires a clean master checkout.'
fi
LOCAL_SHA="$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)"
REMOTE_SHA="$(gh api "repos/${REPOSITORY}/commits/master" --jq .sha)"
if ! [[ "$LOCAL_SHA" =~ ^[a-f0-9]{40}$ ]] || [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    fail 'Local master does not equal remote master.'
fi

MANAGEMENT_PROJECT_NUMBER="$(gcloud projects describe "$MANAGEMENT_PROJECT_ID" --format='value(projectNumber)')"
if ! [[ "$MANAGEMENT_PROJECT_NUMBER" =~ ^[0-9]+$ ]]; then
    fail 'Management project number is invalid.'
fi
STATE_BUCKET="${MANAGEMENT_PROJECT_ID}-${MANAGEMENT_PROJECT_NUMBER}-tofu-state"
OPERATOR_EMAIL="$(gcloud config get-value account 2>/dev/null)"
if ! [[ "$OPERATOR_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    fail 'Active Google account is invalid.'
fi
export TF_IN_AUTOMATION=true
export TF_VAR_management_project_id="$MANAGEMENT_PROJECT_ID"
TF_VAR_operator_principals="$(jq -cn \
    --arg principal "user:${OPERATOR_EMAIL}" '[$principal]')"
export TF_VAR_operator_principals

write_metadata() {
    local plan_sha
    local temporary_metadata

    chmod 600 "$PLAN_FILE"
    plan_sha="$(sha256sum "$PLAN_FILE" | cut -d ' ' -f 1)"
    temporary_metadata="$(mktemp "${METADATA_FILE}.XXXXXX")"
    cleanup_metadata() {
        rm -f -- "$temporary_metadata"
    }
    trap cleanup_metadata INT TERM EXIT
    jq -n \
        --arg project "$MANAGEMENT_PROJECT_ID" \
        --arg bucket "$STATE_BUCKET" \
        --arg commit "$LOCAL_SHA" \
        --arg sha256 "$plan_sha" '
          {
            schemaVersion: 1,
            root: "bootstrap",
            managementProjectId: $project,
            stateBucket: $bucket,
            commit: $commit,
            sha256: $sha256,
            consumed: false
          }
        ' >"$temporary_metadata"
    chmod 600 "$temporary_metadata"
    mv -- "$temporary_metadata" "$METADATA_FILE"
    trap - INT TERM EXIT
}

consume_metadata() {
    local temporary_metadata

    temporary_metadata="$(mktemp "${METADATA_FILE}.XXXXXX")"
    cleanup_metadata() {
        rm -f -- "$temporary_metadata"
    }
    trap cleanup_metadata INT TERM EXIT
    jq '.consumed = true' "$METADATA_FILE" >"$temporary_metadata"
    chmod 600 "$temporary_metadata"
    mv -- "$temporary_metadata" "$METADATA_FILE"
    trap - INT TERM EXIT
}

case "$ACTION" in
    plan)
        if [ -e "$PLAN_FILE" ] || [ -e "$METADATA_FILE" ]; then
            fail 'Choose a new private plan path; bootstrap custody never overwrites a prior review.'
        fi
        PLAN_EXIT=0
        "${SCRIPT_DIR}/tofu-gate.sh" plan bootstrap "$STATE_BUCKET" "$PLAN_FILE" ||
            PLAN_EXIT=$?
        case "$PLAN_EXIT" in
            0 | 2)
                write_metadata
                printf 'Bootstrap plan custody recorded commit %s.\n' "$LOCAL_SHA"
                exit "$PLAN_EXIT"
                ;;
            *)
                rm -f -- "$PLAN_FILE"
                exit "$PLAN_EXIT"
                ;;
        esac
        ;;
    apply)
        if [ ! -f "$PLAN_FILE" ] || [ ! -f "$METADATA_FILE" ]; then
            fail 'The reviewed bootstrap plan or its custody metadata is missing.' 66
        fi
        PLAN_SHA="$(sha256sum "$PLAN_FILE" | cut -d ' ' -f 1)"
        if ! jq --exit-status \
            --arg project "$MANAGEMENT_PROJECT_ID" \
            --arg bucket "$STATE_BUCKET" \
            --arg commit "$LOCAL_SHA" \
            --arg sha256 "$PLAN_SHA" '
              .schemaVersion == 1 and
              .root == "bootstrap" and
              .managementProjectId == $project and
              .stateBucket == $bucket and
              .commit == $commit and
              .sha256 == $sha256 and
              .consumed == false
            ' "$METADATA_FILE" >/dev/null; then
            fail 'Bootstrap plan custody does not match this project, commit, or plan.'
        fi

        # Consume before mutation. A partial apply must be diagnosed and
        # replanned instead of replaying a stale binary plan.
        consume_metadata
        cleanup_consumed_plan() {
            rm -f -- "$PLAN_FILE"
        }
        trap cleanup_consumed_plan INT TERM EXIT
        APPLY_EXIT=0
        "${SCRIPT_DIR}/tofu-gate.sh" apply bootstrap "$STATE_BUCKET" "$PLAN_FILE" ||
            APPLY_EXIT=$?
        cleanup_consumed_plan
        trap - INT TERM EXIT
        if [ "$APPLY_EXIT" -ne 0 ]; then
            exit "$APPLY_EXIT"
        fi
        printf 'The exact reviewed local bootstrap plan was consumed.\n'
        ;;
esac
