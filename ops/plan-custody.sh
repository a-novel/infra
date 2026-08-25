#!/bin/bash

# Publishes, verifies, or consumes an opaque reviewed plan in the private state
# bucket. Metadata binds it to one root, commit, run, hash, and 24-hour window.
# Usage: plan-custody.sh publish <bucket> <root> <commit> <plan-id> <plan-file> <true|false>
#        plan-custody.sh fetch   <bucket> <root> <commit> <plan-id> <plan-file>
#        plan-custody.sh consume <bucket> <root> <commit> <plan-id>

set -euo pipefail

if [ "$#" -lt 5 ] || [ "$#" -gt 7 ]; then
    printf 'Usage: %s <publish|fetch|consume> <bucket> <root> <commit> <plan-id> [plan-file] [destructive]\n' "$0" >&2
    exit 64
fi

ACTION="$1"
BUCKET="$2"
ROOT_NAME="$3"
COMMIT="$4"
PLAN_ID="$5"
PLAN_FILE="${6:-}"
DESTRUCTIVE="${7:-}"
STATE_SUFFIX="${TOFU_STATE_SUFFIX:-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=ops/lib/roots.sh
. "${SCRIPT_DIR}/lib/roots.sh"

resolve_root "${REPOSITORY_ROOT}" "${ROOT_NAME}" >/dev/null

if ! [[ "${BUCKET}" =~ ^[a-z0-9][a-z0-9._-]{1,221}[a-z0-9]$ ]] ||
    ! [[ "${COMMIT}" =~ ^[a-f0-9]{40}$ ]] ||
    ! [[ "${PLAN_ID}" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]]; then
    printf 'Invalid plan-custody identifier.\n' >&2
    exit 65
fi

if [ -n "${STATE_SUFFIX}" ] &&
    ! [[ "${STATE_SUFFIX}" =~ ^recovery/[a-z0-9][a-z0-9-]{0,62}$ ]]; then
    printf 'Invalid recovery state suffix.\n' >&2
    exit 65
fi

case "${ACTION}" in
    publish)
        if [ "$#" -ne 7 ] || [ ! -f "${PLAN_FILE}" ] ||
            { [ "${DESTRUCTIVE}" != 'true' ] && [ "${DESTRUCTIVE}" != 'false' ]; }; then
            printf 'Publish requires a plan file and a true/false destructive marker.\n' >&2
            exit 64
        fi
        ;;
    fetch)
        if [ "$#" -ne 6 ] || [ -z "${PLAN_FILE}" ]; then
            printf 'Fetch requires a destination plan file.\n' >&2
            exit 64
        fi
        ;;
    consume)
        if [ "$#" -ne 5 ]; then
            printf 'Consume accepts no plan file.\n' >&2
            exit 64
        fi
        ;;
    *)
        printf 'Unknown plan-custody action.\n' >&2
        exit 64
        ;;
esac

for command_name in gcloud jq sha256sum; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required by the protected plan environment.\n' "${command_name}" >&2
        exit 69
    fi
done

TEMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf -- "${TEMP_DIR}"
}
trap cleanup INT TERM EXIT
chmod 0700 "${TEMP_DIR}"

OBJECT_PREFIX="gs://${BUCKET}/${ROOT_NAME}/plans"
if [ -n "${STATE_SUFFIX}" ]; then
    OBJECT_PREFIX="${OBJECT_PREFIX}/${STATE_SUFFIX}"
fi
OBJECT_PREFIX="${OBJECT_PREFIX}/${COMMIT}/${PLAN_ID}"
PLAN_OBJECT="${OBJECT_PREFIX}/plan.tfplan"
METADATA_OBJECT="${OBJECT_PREFIX}/metadata.json"
METADATA_FILE="${TEMP_DIR}/metadata.json"

case "${ACTION}" in
    publish)
        CREATED_EPOCH="$(date -u +%s)"
        EXPIRES_EPOCH=$((CREATED_EPOCH + 86400))
        PLAN_SHA256="$(sha256sum "${PLAN_FILE}" | cut -d ' ' -f 1)"

        jq -n \
            --arg root "${ROOT_NAME}" \
            --arg commit "${COMMIT}" \
            --arg plan_id "${PLAN_ID}" \
            --arg state_suffix "${STATE_SUFFIX}" \
            --arg sha256 "${PLAN_SHA256}" \
            --argjson created_epoch "${CREATED_EPOCH}" \
            --argjson expires_epoch "${EXPIRES_EPOCH}" \
            --argjson destructive "${DESTRUCTIVE}" \
            '{
              schemaVersion: 1,
              root: $root,
              commit: $commit,
              planId: $plan_id,
              stateSuffix: $state_suffix,
              sha256: $sha256,
              createdEpoch: $created_epoch,
              expiresEpoch: $expires_epoch,
              destructive: $destructive
            }' >"${METADATA_FILE}"
        chmod 0600 "${METADATA_FILE}" "${PLAN_FILE}"

        if ! gcloud storage cp "${PLAN_FILE}" "${PLAN_OBJECT}" \
            --if-generation-match=0 --quiet >/dev/null 2>&1; then
            printf 'The private plan object already exists or could not be stored.\n' >&2
            exit 70
        fi

        if ! gcloud storage cp "${METADATA_FILE}" "${METADATA_OBJECT}" \
            --if-generation-match=0 --quiet >/dev/null 2>&1; then
            gcloud storage rm "${PLAN_OBJECT}" --quiet >/dev/null 2>&1 || true
            printf 'The private plan metadata already exists or could not be stored.\n' >&2
            exit 70
        fi

        printf 'Stored %s plan %s; it expires in 24 hours and is bound to commit %s.\n' \
            "${ROOT_NAME}" "${PLAN_ID}" "${COMMIT}"
        ;;
    fetch)
        if ! gcloud storage cp "${METADATA_OBJECT}" "${METADATA_FILE}" \
            --quiet >/dev/null 2>&1; then
            printf 'The reviewed plan metadata is unavailable.\n' >&2
            exit 66
        fi

        NOW_EPOCH="$(date -u +%s)"
        if ! jq --exit-status \
            --arg root "${ROOT_NAME}" \
            --arg commit "${COMMIT}" \
            --arg plan_id "${PLAN_ID}" \
            --arg state_suffix "${STATE_SUFFIX}" \
            --argjson now "${NOW_EPOCH}" '
                type == "object"
                and keys == ["commit", "createdEpoch", "destructive", "expiresEpoch", "planId", "root", "schemaVersion", "sha256", "stateSuffix"]
                and .schemaVersion == 1
                and .root == $root
                and .commit == $commit
                and .planId == $plan_id
                and .stateSuffix == $state_suffix
                and (.sha256 | test("^[a-f0-9]{64}$"))
                and (.destructive | type == "boolean")
                and (.createdEpoch | type == "number")
                and (.expiresEpoch | type == "number")
                and .createdEpoch <= ($now + 300)
                and .expiresEpoch == (.createdEpoch + 86400)
                and $now < .expiresEpoch
            ' "${METADATA_FILE}" >/dev/null; then
            printf 'The reviewed plan is stale, replayed, or does not match this commit and root.\n' >&2
            exit 77
        fi

        if ! gcloud storage cp "${PLAN_OBJECT}" "${PLAN_FILE}" \
            --quiet >/dev/null 2>&1; then
            printf 'The reviewed opaque plan is unavailable.\n' >&2
            exit 66
        fi
        chmod 0600 "${PLAN_FILE}"

        EXPECTED_SHA256="$(jq --raw-output .sha256 "${METADATA_FILE}")"
        ACTUAL_SHA256="$(sha256sum "${PLAN_FILE}" | cut -d ' ' -f 1)"
        if [ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]; then
            rm -f -- "${PLAN_FILE}"
            printf 'The reviewed plan hash does not match its private metadata.\n' >&2
            exit 77
        fi

        jq --raw-output '.destructive' "${METADATA_FILE}" >"${PLAN_FILE}.destructive"
        chmod 0600 "${PLAN_FILE}.destructive"
        printf 'Verified exact unexpired %s plan %s for commit %s.\n' \
            "${ROOT_NAME}" "${PLAN_ID}" "${COMMIT}"
        ;;
    consume)
        if ! gcloud storage rm "${PLAN_OBJECT}" "${METADATA_OBJECT}" \
            --quiet >/dev/null 2>&1; then
            printf 'The reviewed plan could not be consumed; apply remains blocked.\n' >&2
            exit 70
        fi
        printf 'Consumed reviewed %s plan %s.\n' "${ROOT_NAME}" "${PLAN_ID}"
        ;;
esac
