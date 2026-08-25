#!/bin/bash

# Preserve the exact private variable file that most recently converged each
# root. Immutable, run-ordered objects let the cloud-blind drift workflow read
# current inputs without GitHub environment secrets or mutable pointers.
# Usage: config-custody.sh <publish|fetch> <bucket> <root> <file> [run-id] [run-attempt]

set -euo pipefail

if [ "$#" -lt 4 ] || [ "$#" -gt 6 ]; then
    printf 'Usage: %s <publish|fetch> <bucket> <root> <file> [run-id] [run-attempt]\n' "$0" >&2
    exit 64
fi

ACTION="$1"
BUCKET="$2"
ROOT_NAME="$3"
FILE="$4"
RUN_ID="${5:-}"
RUN_ATTEMPT="${6:-}"
PREFIX="gs://${BUCKET}/${ROOT_NAME}/config"

case "${ROOT_NAME}" in
    bootstrap | foundation | release) ;;
    *)
        printf 'Invalid root name.\n' >&2
        exit 65
        ;;
esac

if ! [[ "${BUCKET}" =~ ^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$ ]] ||
    ! command -v gcloud >/dev/null 2>&1 ||
    ! command -v jq >/dev/null 2>&1; then
    printf 'Private configuration custody prerequisites are invalid.\n' >&2
    exit 69
fi

case "${ACTION}" in
    publish)
        if [ "$#" -ne 6 ] || [ ! -f "${FILE}" ] ||
            ! [[ "${RUN_ID}" =~ ^[1-9][0-9]*$ ]] ||
            ! [[ "${RUN_ATTEMPT}" =~ ^[1-9][0-9]*$ ]] ||
            ! jq --exit-status 'type == "object"' "${FILE}" >/dev/null; then
            printf 'Invalid private configuration publication.\n' >&2
            exit 65
        fi
        PADDED_RUN_ID="$(printf '%020s' "${RUN_ID}")"
        PADDED_RUN_ID="${PADDED_RUN_ID// /0}"
        PADDED_RUN_ATTEMPT="$(printf '%05s' "${RUN_ATTEMPT}")"
        PADDED_RUN_ATTEMPT="${PADDED_RUN_ATTEMPT// /0}"
        DESTINATION="${PREFIX}/${PADDED_RUN_ID}-${PADDED_RUN_ATTEMPT}.tfvars.json"
        if ! gcloud storage cp "${FILE}" "${DESTINATION}" \
            --if-generation-match=0 --quiet >/dev/null 2>&1; then
            printf 'The immutable current configuration could not be stored.\n' >&2
            exit 70
        fi
        printf '%s current configuration published privately.\n' "${ROOT_NAME}"
        ;;
    fetch)
        if [ "$#" -ne 4 ]; then
            printf 'Fetch accepts no workflow run identity.\n' >&2
            exit 64
        fi
        if ! LISTING="$(gcloud storage objects list "${PREFIX}/**" --uri 2>/dev/null)"; then
            printf 'The private configuration inventory could not be listed.\n' >&2
            exit 70
        fi
        URI=""
        while IFS= read -r OBJECT; do
            case "${OBJECT}" in
                "${PREFIX}/"*)
                    NAME="${OBJECT##*/}"
                    if ! [[ "${NAME}" =~ ^[0-9]{20}-[0-9]{5}\.tfvars\.json$ ]]; then
                        printf 'The private configuration inventory contains an unexpected object.\n' >&2
                        exit 70
                    fi
                    if [ -z "${URI}" ] || [[ "${OBJECT}" > "${URI}" ]]; then
                        URI="${OBJECT}"
                    fi
                    ;;
            esac
        done <<<"${LISTING}"
        if [ -z "${URI}" ]; then
            exit 4
        fi
        if ! gcloud storage cp "${URI}" "${FILE}" --quiet >/dev/null 2>&1 ||
            ! jq --exit-status 'type == "object"' "${FILE}" >/dev/null; then
            printf 'The current private configuration could not be read.\n' >&2
            exit 70
        fi
        chmod 600 "${FILE}"
        ;;
    *)
        printf 'Unknown private configuration custody action.\n' >&2
        exit 64
        ;;
esac
