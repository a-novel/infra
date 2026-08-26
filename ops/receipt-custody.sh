#!/bin/bash

# Reads and creates immutable production release receipts. Object names embed a
# zero-padded GitHub run ID, so a delayed older run cannot publish over a newer
# deployment. Receipt payloads remain private and are never written to stdout.
# Usage: receipt-custody.sh latest  <bucket> <file>
#        receipt-custody.sh fetch   <bucket> <file> <run-id-attempt>
#        receipt-custody.sh publish <bucket> <file> <run-id> <run-attempt>

set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
    printf 'Usage: %s <latest|publish> <bucket> <file> [run-id] [run-attempt]\n' "$0" >&2
    exit 64
fi

ACTION="$1"
BUCKET="$2"
FILE="$3"
IDENTIFIER="${4:-}"
RUN_ID="${4:-}"
RUN_ATTEMPT="${5:-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RECEIPT_PREFIX="gs://${BUCKET}/production/success"

if ! [[ "${BUCKET}" =~ ^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$ ]]; then
    printf 'Invalid receipt bucket.\n' >&2
    exit 65
fi

for command_name in gcloud jq sha256sum; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required by the protected receipt workflow.\n' "${command_name}" >&2
        exit 69
    fi
done

latest_uri() {
    local listing=""
    local latest=""
    local name=""
    local object=""

    # The object-list API scopes directly to the protected prefix. A successful
    # empty listing is the only condition that means first launch;
    # authentication and transport failures stop.
    if ! listing="$(gcloud storage objects list "${RECEIPT_PREFIX}/**" --uri 2>/dev/null)"; then
        printf 'The release receipt inventory could not be listed.\n' >&2
        return 70
    fi

    while IFS= read -r object; do
        case "${object}" in
            "${RECEIPT_PREFIX}/"*)
                name="${object##*/}"
                if ! [[ "${name}" =~ ^[0-9]{20}-[0-9]{5}\.json$ ]]; then
                    printf 'The release receipt inventory contains an unexpected object.\n' >&2
                    return 70
                fi
                if [ -z "${latest}" ] || [[ "${object}" > "${latest}" ]]; then
                    latest="${object}"
                fi
                ;;
        esac
    done <<<"${listing}"

    if [ -z "${latest}" ]; then
        return 4
    fi
    printf '%s\n' "${latest}"
}

case "${ACTION}" in
    latest)
        if [ "$#" -ne 3 ]; then
            printf 'Latest receipt lookup accepts no run identity.\n' >&2
            exit 64
        fi
        if URI="$(latest_uri)"; then
            :
        else
            LATEST_CODE=$?
            exit "${LATEST_CODE}"
        fi
        if ! gcloud storage cp "${URI}" "${FILE}" --quiet >/dev/null 2>&1; then
            printf 'The latest release receipt could not be read.\n' >&2
            exit 70
        fi
        chmod 600 "${FILE}"
        "${SCRIPT_DIR}/validate-receipt.mjs" "${FILE}"
        ;;
    fetch)
        if [ "$#" -ne 4 ] || ! [[ "${IDENTIFIER}" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]]; then
            printf 'Receipt fetch requires a run-id-attempt identifier.\n' >&2
            exit 64
        fi
        FETCH_RUN_ID="${IDENTIFIER%%-*}"
        FETCH_ATTEMPT="${IDENTIFIER#*-}"
        PADDED_FETCH_RUN_ID="$(printf '%020s' "${FETCH_RUN_ID}")"
        PADDED_FETCH_RUN_ID="${PADDED_FETCH_RUN_ID// /0}"
        PADDED_FETCH_ATTEMPT="$(printf '%05s' "${FETCH_ATTEMPT}")"
        PADDED_FETCH_ATTEMPT="${PADDED_FETCH_ATTEMPT// /0}"
        URI="${RECEIPT_PREFIX}/${PADDED_FETCH_RUN_ID}-${PADDED_FETCH_ATTEMPT}.json"
        if ! gcloud storage cp "${URI}" "${FILE}" --quiet >/dev/null 2>&1; then
            printf 'The selected release receipt could not be read.\n' >&2
            exit 70
        fi
        chmod 600 "${FILE}"
        "${SCRIPT_DIR}/validate-receipt.mjs" "${FILE}"
        ;;
    publish)
        if [ "$#" -ne 5 ] || ! [[ "${RUN_ID}" =~ ^[1-9][0-9]*$ ]] ||
            ! [[ "${RUN_ATTEMPT}" =~ ^[1-9][0-9]*$ ]]; then
            printf 'Publish requires a valid GitHub run ID and attempt.\n' >&2
            exit 64
        fi
        "${SCRIPT_DIR}/validate-receipt.mjs" "${FILE}"
        if ! jq --exit-status \
            --arg run_id "${RUN_ID}" \
            --argjson run_attempt "${RUN_ATTEMPT}" \
            '.sequence.runId == $run_id and .sequence.runAttempt == $run_attempt' \
            "${FILE}" >/dev/null; then
            printf 'Receipt sequence does not match this workflow run.\n' >&2
            exit 65
        fi

        PADDED_RUN_ID="$(printf '%020s' "${RUN_ID}")"
        PADDED_RUN_ID="${PADDED_RUN_ID// /0}"
        PADDED_RUN_ATTEMPT="$(printf '%05s' "${RUN_ATTEMPT}")"
        PADDED_RUN_ATTEMPT="${PADDED_RUN_ATTEMPT// /0}"
        RECEIPT_NAME="${PADDED_RUN_ID}-${PADDED_RUN_ATTEMPT}.json"
        if URI="$(latest_uri)"; then
            LATEST_NAME="${URI##*/}"
            if [[ "${LATEST_NAME}" > "${RECEIPT_NAME}" ]]; then
                printf 'A newer production release receipt already exists.\n' >&2
                exit 70
            fi
        else
            LATEST_CODE=$?
            if [ "${LATEST_CODE}" -ne 4 ]; then
                exit "${LATEST_CODE}"
            fi
        fi

        DESTINATION="${RECEIPT_PREFIX}/${RECEIPT_NAME}"
        if ! gcloud storage cp "${FILE}" "${DESTINATION}" \
            --if-generation-match=0 \
            --quiet >/dev/null 2>&1; then
            # A create may have committed even if its response was lost. Read
            # back the immutable name and accept only byte-identical content;
            # a genuinely different collision remains fatal.
            EXISTING_RECEIPT="$(mktemp)"
            chmod 600 "${EXISTING_RECEIPT}"
            if ! gcloud storage cp "${DESTINATION}" "${EXISTING_RECEIPT}" \
                --quiet >/dev/null 2>&1; then
                rm -f -- "${EXISTING_RECEIPT}"
                printf 'The immutable release receipt could not be created.\n' >&2
                exit 70
            fi
            LOCAL_RECEIPT_SHA256="$(sha256sum "${FILE}" | cut -d ' ' -f 1)"
            EXISTING_RECEIPT_SHA256="$(sha256sum "${EXISTING_RECEIPT}" | cut -d ' ' -f 1)"
            if [ "${LOCAL_RECEIPT_SHA256}" != "${EXISTING_RECEIPT_SHA256}" ]; then
                rm -f -- "${EXISTING_RECEIPT}"
                printf 'The immutable release receipt could not be created.\n' >&2
                exit 70
            fi
            rm -f -- "${EXISTING_RECEIPT}"
        fi
        printf 'Immutable production release receipt published.\n'
        ;;
    *)
        printf 'Unknown receipt custody action.\n' >&2
        exit 64
        ;;
esac
