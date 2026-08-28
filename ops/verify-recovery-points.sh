#!/bin/bash

# Verify the two exact committed backup manifests selected by the operator and
# print only their timestamps and worst-case lost-write windows. Dump payloads
# remain private and are validated inside the recovery containers. An optional
# private JSON file carries the same bounded metadata into the recovery receipt.
# Usage: verify-recovery-points.sh <bucket> <receipt> <json-attempt> <auth-attempt> [metadata]

set -euo pipefail

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
    printf 'Usage: %s <bucket> <receipt> <json-attempt> <auth-attempt> [metadata]\n' "$0" >&2
    exit 64
fi

umask 077
BUCKET="$1"
RECEIPT_FILE="$2"
JSON_ATTEMPT="$3"
AUTHENTICATION_ATTEMPT="$4"
METADATA_FILE="${5:-}"
SCRATCH_DIRECTORY="$(mktemp -d)"
trap 'rm -rf -- "${SCRATCH_DIRECTORY}"' EXIT

SOURCE_PROJECT="$(jq --raw-output '.activeTfvars.workload_project_id' "${RECEIPT_FILE}")"
NOW_EPOCH="$(date -u +%s)"
JSON_KEYS_COMPLETED=0
JSON_KEYS_AGE=0
AUTHENTICATION_COMPLETED=0
AUTHENTICATION_AGE=0

verify_point() {
    local key="$1"
    local attempt="$2"
    local expected_image="$3"
    local manifest="${SCRATCH_DIRECTORY}/${key}.manifest"
    local completed=""
    local age=0

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
    # Accept bounded clock skew without turning it into a negative RPO value.
    # A future timestamp beyond the five-minute tolerance already fails above.
    if [ "${completed}" -gt "${NOW_EPOCH}" ]; then
        age=0
    else
        age="$((NOW_EPOCH - completed))"
    fi
    case "${key}" in
        json-keys)
            JSON_KEYS_COMPLETED="${completed}"
            JSON_KEYS_AGE="${age}"
            ;;
        authentication)
            AUTHENTICATION_COMPLETED="${completed}"
            AUTHENTICATION_AGE="${age}"
            ;;
    esac
    printf '%s recovery point: %s UTC; at most %s seconds of writes precede this run.\n' \
        "${key}" "$(date -u --date="@${completed}" +%Y-%m-%dT%H:%M:%SZ)" \
        "${age}"
}

verify_point json-keys "${JSON_ATTEMPT}" \
    "$(jq --raw-output '.database.jsonKeysImage' "${RECEIPT_FILE}")"
verify_point authentication "${AUTHENTICATION_ATTEMPT}" \
    "$(jq --raw-output '.database.authenticationImage' "${RECEIPT_FILE}")"

if [ -n "${METADATA_FILE}" ]; then
    jq -n \
        --argjson observed_at_epoch "${NOW_EPOCH}" \
        --argjson json_keys_completed "${JSON_KEYS_COMPLETED}" \
        --argjson json_keys_age "${JSON_KEYS_AGE}" \
        --argjson authentication_completed "${AUTHENTICATION_COMPLETED}" \
        --argjson authentication_age "${AUTHENTICATION_AGE}" '
        {
          schemaVersion: 1,
          observedAt: ($observed_at_epoch | strftime("%Y-%m-%dT%H:%M:%SZ")),
          observedAtEpoch: $observed_at_epoch,
          databases: {
            jsonKeys: {
              completedAt: ($json_keys_completed | strftime("%Y-%m-%dT%H:%M:%SZ")),
              completedEpoch: $json_keys_completed,
              ageSeconds: $json_keys_age
            },
            authentication: {
              completedAt: ($authentication_completed | strftime("%Y-%m-%dT%H:%M:%SZ")),
              completedEpoch: $authentication_completed,
              ageSeconds: $authentication_age
            }
          },
          maxLostWriteWindowSeconds: ([$json_keys_age, $authentication_age] | max)
        }
    ' >"${METADATA_FILE}"
    chmod 600 "${METADATA_FILE}"
fi
