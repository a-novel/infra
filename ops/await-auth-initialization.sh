#!/bin/bash

# The release identity can observe but never deploy or execute the one-time
# initializer. On first launch this gate waits for a named operator to provision
# the human-only job through the runbook and run it once, then creates a single
# immutable completion marker in the private receipt bucket.
# Usage: await-auth-initialization.sh <project> <region> <receipt-bucket> <commit>

set -euo pipefail

if [ "$#" -ne 4 ]; then
    printf 'Usage: %s <project> <region> <receipt-bucket> <commit>\n' "$0" >&2
    exit 64
fi

PROJECT_ID="$1"
REGION="$2"
RECEIPT_BUCKET="$3"
COMMIT="$4"
JOB_NAME="agora-authentication-init"
MARKER="gs://${RECEIPT_BUCKET}/production/initialization/complete.json"
POLL_SECONDS="${INITIALIZATION_POLL_SECONDS:-20}"
MAX_POLLS="${INITIALIZATION_MAX_POLLS:-90}"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SCRATCH_DIRECTORY="$(mktemp -d)"
trap 'rm -rf -- "${SCRATCH_DIRECTORY}"' EXIT

if ! [[ "${PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    ! [[ "${REGION}" =~ ^[a-z]+-[a-z]+[0-9]+$ ]] ||
    ! [[ "${COMMIT}" =~ ^[a-f0-9]{40}$ ]] ||
    ! [[ "${POLL_SECONDS}" =~ ^[0-9]+$ ]] ||
    ! [[ "${MAX_POLLS}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Invalid Authentication initialization gate input.\n' >&2
    exit 65
fi

for command_name in gcloud jq; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required by the protected initialization gate.\n' "${command_name}" >&2
        exit 69
    fi
done

valid_marker() {
    jq --exit-status '
        type == "object" and
        keys == ["commit", "completedAt", "execution", "schemaVersion"] and
        .schemaVersion == 1 and
        (.commit | test("^[a-f0-9]{40}$")) and
        (.execution | test("^agora-authentication-init-[a-z0-9]+$")) and
        (.completedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      ' "$1" >/dev/null
}

EXISTING_MARKER="${SCRATCH_DIRECTORY}/existing-initialization.json"
if ! MARKER_LISTING="$(gcloud storage objects list "gs://${RECEIPT_BUCKET}/production/initialization/**" --uri 2>/dev/null)"; then
    printf 'The Authentication initialization inventory could not be listed.\n' >&2
    exit 70
fi
MARKER_PRESENT=false
while IFS= read -r object; do
    if [ "${object}" = "${MARKER}" ]; then
        MARKER_PRESENT=true
    fi
done <<<"${MARKER_LISTING}"

if [ "${MARKER_PRESENT}" = true ]; then
    if ! gcloud storage cp "${MARKER}" "${EXISTING_MARKER}" \
        --quiet >/dev/null 2>&1; then
        printf 'The immutable Authentication initialization marker could not be read.\n' >&2
        exit 70
    fi
    if ! valid_marker "${EXISTING_MARKER}"; then
        printf 'The immutable Authentication initialization marker is invalid.\n' >&2
        exit 70
    fi
    jq --raw-output '.execution' "${EXISTING_MARKER}"
    exit 0
fi

printf '\nAuthentication requires its one-time, human-only initialization.\n' >&2
printf 'An approved initializer must first follow the two-phase setup in:\n' >&2
printf 'docs/setup-production.md#run-the-human-only-authentication-initializer\n\n' >&2
printf 'After that setup, run exactly:\n\n' >&2
printf 'gcloud run jobs execute %s --project=%s --region=%s --wait\n\n' \
    "${JOB_NAME}" "${PROJECT_ID}" "${REGION}" >&2
printf 'The release will wait for a successful exact execution; overrides are not permitted.\n' >&2

for ((attempt = 1; attempt <= MAX_POLLS; attempt++)); do
    EXECUTIONS_FILE="${SCRATCH_DIRECTORY}/executions.json"
    if gcloud run jobs executions list \
        --job="${JOB_NAME}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --format=json >"${EXECUTIONS_FILE}" 2>/dev/null; then
        EXECUTION="$(
            jq --exit-status --raw-output \
                --arg started_at "${STARTED_AT}" '
                  [ .[] | select(
                      .metadata.creationTimestamp >= $started_at and
                      any(.status.conditions[]?;
                        .type == "Completed" and .status == "True"
                      )
                    ) ]
                  | sort_by(.metadata.creationTimestamp)
                  | last
                  | .metadata.name
                ' "${EXECUTIONS_FILE}" 2>/dev/null || true
        )"
        EXECUTION="${EXECUTION##*/}"
        if [ -n "${EXECUTION}" ] && [[ "${EXECUTION}" =~ ^agora-authentication-init-[a-z0-9]+$ ]]; then
            MARKER_FILE="${SCRATCH_DIRECTORY}/initialization.json"
            jq -n \
                --arg commit "${COMMIT}" \
                --arg execution "${EXECUTION}" \
                --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{schemaVersion: 1, commit: $commit, execution: $execution, completedAt: $completed_at}' \
                >"${MARKER_FILE}"
            chmod 600 "${MARKER_FILE}"
            if ! gcloud storage cp "${MARKER_FILE}" "${MARKER}" \
                --if-generation-match=0 --quiet >/dev/null 2>&1; then
                # A concurrent successful first-launch gate may have created
                # the same one-time marker; accept only the full exact schema.
                if ! gcloud storage cp "${MARKER}" "${EXISTING_MARKER}" \
                    --quiet >/dev/null 2>&1 ||
                    ! valid_marker "${EXISTING_MARKER}"; then
                    printf 'Initialization succeeded but its immutable marker could not be stored.\n' >&2
                    exit 70
                fi
                EXECUTION="$(jq --raw-output '.execution' "${EXISTING_MARKER}")"
            fi
            printf '%s\n' "${EXECUTION}"
            exit 0
        fi
    fi
    if [ "${attempt}" -lt "${MAX_POLLS}" ]; then
        sleep "${POLL_SECONDS}"
    fi
done

printf 'No successful, post-gate Authentication initializer execution was observed.\n' >&2
exit 70
