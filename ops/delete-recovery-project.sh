#!/bin/bash

# Deletes one disposable recovery project only when the current merge commit,
# committed target, typed confirmation, project labels, and IAM boundary agree.
# Usage: delete-recovery-project.sh <owner/repository> <commit> <project> <source-receipt> <foundation-config> <authorization> <confirmation>

set -euo pipefail

if [ "$#" -ne 7 ]; then
    printf 'Usage: %s <owner/repository> <commit> <project> <source-receipt> <foundation-config> <authorization> <confirmation>\n' "$0" >&2
    exit 64
fi

REPOSITORY="$1"
COMMIT="$2"
REPLACEMENT_PROJECT="$3"
SOURCE_RECEIPT="$4"
FOUNDATION_CONFIG="$5"
AUTHORIZATION_FILE="$6"
CONFIRMATION="$7"
PROJECT_DELETER_ROLE='roles/resourcemanager.projectDeleter'

if ! [[ "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    ! [[ "${COMMIT}" =~ ^[a-f0-9]{40}$ ]] ||
    ! [[ "${REPLACEMENT_PROJECT}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    ! [[ "${SOURCE_RECEIPT}" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]] ||
    [ "${CONFIRMATION}" != "DELETE ${REPLACEMENT_PROJECT}" ] ||
    [ ! -f "${FOUNDATION_CONFIG}" ] || [ ! -f "${AUTHORIZATION_FILE}" ]; then
    printf 'Recovery cleanup inputs or typed confirmation are invalid.\n' >&2
    exit 65
fi

for command_name in gcloud jq; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required by the protected recovery environment.\n' "${command_name}" >&2
        exit 69
    fi
done

if ! MANAGEMENT_PROJECT="$(jq --exit-status --raw-output '.management_project_id | select(type == "string")' "${FOUNDATION_CONFIG}")" ||
    ! PRODUCTION_PROJECT="$(jq --exit-status --raw-output '.workload_project_id | select(type == "string")' "${FOUNDATION_CONFIG}")" ||
    ! [[ "${MANAGEMENT_PROJECT}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    ! [[ "${PRODUCTION_PROJECT}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    [ "${REPLACEMENT_PROJECT}" = "${MANAGEMENT_PROJECT}" ] ||
    [ "${REPLACEMENT_PROJECT}" = "${PRODUCTION_PROJECT}" ]; then
    printf 'Recovery cleanup cannot target a management or production project.\n' >&2
    exit 77
fi

# The exact target is a reviewed code change. The Boolean records the human
# operator's completed absence checks for every temporary cross-project grant.
if ! jq --exit-status \
    --arg project "${REPLACEMENT_PROJECT}" --arg receipt "${SOURCE_RECEIPT}" '
      .schemaVersion == 1 and
      .replacementProject == $project and
      .sourceReceipt == $receipt and
      .crossProjectAccessRevoked == true and
      (keys | sort) == [
        "crossProjectAccessRevoked",
        "replacementProject",
        "schemaVersion",
        "sourceReceipt"
      ]
    ' "${AUTHORIZATION_FILE}" >/dev/null; then
    printf 'The committed recovery-cleanup authorization does not match this target.\n' >&2
    exit 77
fi

"$(dirname -- "$0")/verify-deletion-label.sh" "${REPOSITORY}" "${COMMIT}"

if ! PROJECT_METADATA="$(gcloud projects describe "${REPLACEMENT_PROJECT}" --format=json 2>/dev/null)" ||
    ! jq --exit-status --arg project "${REPLACEMENT_PROJECT}" '
      .projectId == $project and
      .lifecycleState == "ACTIVE" and
      .labels.application == "agora" and
      .labels.environment == "production" and
      .labels["managed-by"] == "opentofu" and
      .labels.plane == "workload" and
      .labels.recovery == "true"
    ' <<<"${PROJECT_METADATA}" >/dev/null; then
    printf 'The target is not an active, code-managed disposable recovery project.\n' >&2
    exit 77
fi

RECOVERY_ACCOUNT="infra-recovery@${MANAGEMENT_PROJECT}.iam.gserviceaccount.com"
if ! BOUND_ROLE="$(gcloud projects get-iam-policy "${REPLACEMENT_PROJECT}" \
    --flatten='bindings[].members' \
    --filter="bindings.role=${PROJECT_DELETER_ROLE} AND bindings.members=serviceAccount:${RECOVERY_ACCOUNT}" \
    --format='value(bindings.role)' 2>/dev/null)" ||
    [ "${BOUND_ROLE}" != "${PROJECT_DELETER_ROLE}" ]; then
    printf 'The exact recovery Project Deleter binding is absent.\n' >&2
    exit 77
fi

# Project deletion is the exceptional recovery cleanup boundary. OpenTofu
# keeps its nested state and immutable receipt as evidence; no production root
# or billing-account resource is deleted by this command.
if ! gcloud projects delete "${REPLACEMENT_PROJECT}" \
    --quiet --format=none >/dev/null 2>&1; then
    printf 'The disposable recovery project could not be marked for deletion.\n' >&2
    exit 70
fi

for _ in {1..12}; do
    LIFECYCLE_STATE="$(gcloud projects describe "${REPLACEMENT_PROJECT}" \
        --format='value(lifecycleState)' 2>/dev/null || true)"
    if [ "${LIFECYCLE_STATE}" = DELETE_REQUESTED ]; then
        printf 'Disposable recovery project is DELETE_REQUESTED.\n'
        exit 0
    fi
    sleep 5
done

printf 'Project deletion was requested but its lifecycle state was not confirmed.\n' >&2
exit 70
