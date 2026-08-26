#!/bin/bash

# Verify the two exact committed backup manifests selected by the operator and
# print only their timestamps and worst-case lost-write windows. Dump payloads
# remain private and are validated inside the recovery containers.
# Usage: verify-recovery-points.sh <bucket> <receipt> <json-attempt> <auth-attempt>

set -euo pipefail

if [ "$#" -ne 4 ]; then
    printf 'Usage: %s <bucket> <receipt> <json-attempt> <auth-attempt>\n' "$0" >&2
    exit 64
fi

BUCKET="$1"
RECEIPT_FILE="$2"
JSON_ATTEMPT="$3"
AUTHENTICATION_ATTEMPT="$4"
SCRATCH_DIRECTORY="$(mktemp -d)"
trap 'rm -rf -- "${SCRATCH_DIRECTORY}"' EXIT

SOURCE_PROJECT="$(jq --raw-output '.activeTfvars.workload_project_id' "${RECEIPT_FILE}")"
NOW_EPOCH="$(date -u +%s)"

verify_point() {
    local key="$1"
    local attempt="$2"
    local expected_image="$3"
    local manifest="${SCRATCH_DIRECTORY}/${key}.manifest"
    local completed=""

    if ! [[ "${attempt}" =~ ^[0-9]+-[a-z0-9-]{1,63}-[0-9]+$ ]]; then
        printf 'Invalid exact recovery attempt.\n' >&2
        return 65
    fi
    if ! gcloud storage cp \
        "gs://${BUCKET}/v1/${key}/attempts/${attempt}/completed.manifest" \
        "${manifest}" --quiet >/dev/null 2>&1; then
        printf 'A selected recovery manifest is unavailable.\n' >&2
        return 70
    fi
    if [ "$(wc -l <"${manifest}")" -ne 18 ] ||
        [ "$(sed -n 's/^format=//p' "${manifest}")" != agora-postgres-backup-v1 ] ||
        [ "$(sed -n 's/^source_project=//p' "${manifest}")" != "${SOURCE_PROJECT}" ] ||
        [ "$(sed -n 's/^database_image=//p' "${manifest}")" != "${expected_image}" ] ||
        [ "$(sed -n 's/^postgres_major=//p' "${manifest}")" != 18 ]; then
        printf 'A selected recovery manifest does not match its immutable receipt.\n' >&2
        return 70
    fi
    completed="$(sed -n 's/^completed_epoch=//p' "${manifest}")"
    if ! [[ "${completed}" =~ ^[0-9]+$ ]] ||
        [ "${completed}" -gt "$((NOW_EPOCH + 300))" ] ||
        [ "$((NOW_EPOCH - completed))" -gt 1209600 ]; then
        printf 'A selected recovery point is invalid or outside retained storage.\n' >&2
        return 70
    fi
    printf '%s recovery point: %s UTC; at most %s seconds of writes precede this run.\n' \
        "${key}" "$(date -u --date="@${completed}" +%Y-%m-%dT%H:%M:%SZ)" \
        "$((NOW_EPOCH - completed))"
}

verify_point json-keys "${JSON_ATTEMPT}" \
    "$(jq --raw-output '.database.jsonKeysImage' "${RECEIPT_FILE}")"
verify_point authentication "${AUTHENTICATION_ATTEMPT}" \
    "$(jq --raw-output '.database.authenticationImage' "${RECEIPT_FILE}")"
