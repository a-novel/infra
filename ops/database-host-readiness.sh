#!/bin/bash

# Reads or waits for the database host's non-secret startup status.
# Usage: database-host-readiness.sh current <project> <zone>
#        database-host-readiness.sh wait <project> <zone> <revision|none> <previous-status>

set -euo pipefail

DATABASE_GROUP="agora-database"
GUEST_NAMESPACE="agora"
GUEST_KEY="database-release"
GUEST_STATUS=""
DATABASE_INSTANCE=""
READINESS_ERROR_FILE=""

usage() {
    printf 'Usage: %s current <project> <zone>\n' "$0" >&2
    printf '       %s wait <project> <zone> <revision|none> <previous-status>\n' "$0" >&2
    exit 64
}

require_coordinates() {
    if ! [[ "$1" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
        ! [[ "$2" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]]; then
        printf 'Invalid database readiness coordinates.\n' >&2
        exit 65
    fi
}

valid_status() {
    [[ "$1" =~ ^(starting|healthy|idle|failed):(none|invalid|[a-f0-9]{40}):[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]
}

cleanup() {
    if [ -n "${READINESS_ERROR_FILE}" ]; then
        rm -f -- "${READINESS_ERROR_FILE}"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

resolve_database_instance() {
    local instance=""

    if ! instance="$(
        gcloud compute instance-groups managed list-instances "${DATABASE_GROUP}" \
            --project="$1" \
            --zone="$2" \
            --format='value(instance.basename())'
    )"; then
        printf 'The database host could not be selected.\n' >&2
        exit 70
    fi

    if ! [[ "${instance}" =~ ^agora-database-[a-z0-9]+$ ]] || [[ "${instance}" == *$'\n'* ]]; then
        printf 'The database group must contain exactly one generated host.\n' >&2
        exit 70
    fi

    DATABASE_INSTANCE="${instance}"
}

read_guest_status() {
    local status=""

    : >"${READINESS_ERROR_FILE}"
    if ! status="$(
        gcloud compute instances get-guest-attributes "${DATABASE_INSTANCE}" \
            --project="$1" \
            --zone="$2" \
            --query-path="${GUEST_NAMESPACE}/${GUEST_KEY}" \
            --format='value(value)' \
            2>"${READINESS_ERROR_FILE}"
    )"; then
        if grep -Fq 'Guest Attribute' "${READINESS_ERROR_FILE}" &&
            grep -Eiq 'not found|404' "${READINESS_ERROR_FILE}"; then
            GUEST_STATUS="absent"
            return
        fi

        sed -n '1,200p' "${READINESS_ERROR_FILE}" >&2
        printf 'The database host readiness status could not be read.\n' >&2
        exit 70
    fi

    if ! valid_status "${status}"; then
        printf 'The database host readiness status is malformed.\n' >&2
        exit 70
    fi

    GUEST_STATUS="${status}"
}

if ! command -v gcloud >/dev/null 2>&1; then
    printf 'Google Cloud CLI is required by the protected deployment environment.\n' >&2
    exit 69
fi
READINESS_ERROR_FILE="$(mktemp)"

case "${1:-}" in
    current)
        [ "$#" -eq 3 ] || usage
        require_coordinates "$2" "$3"
        resolve_database_instance "$2" "$3"
        read_guest_status "$2" "$3"
        printf '%s\n' "${GUEST_STATUS}"
        ;;
    wait)
        [ "$#" -eq 5 ] || usage
        require_coordinates "$2" "$3"
        if ! [[ "$4" =~ ^([a-f0-9]{40}|none)$ ]] ||
            { [ "$5" != absent ] && ! valid_status "$5"; }; then
            printf 'Invalid database readiness expectation.\n' >&2
            exit 65
        fi

        resolve_database_instance "$2" "$3"
        if [ "$4" = none ]; then
            expected_prefix="idle:none:"
        else
            expected_prefix="healthy:$4:"
        fi

        last_reported_status=""
        for ((attempt = 1; attempt <= 86; attempt++)); do
            read_guest_status "$2" "$3"

            if [ "${GUEST_STATUS}" != "${last_reported_status}" ]; then
                printf 'Database host readiness is %s.\n' "${GUEST_STATUS}" >&2
                last_reported_status="${GUEST_STATUS}"
            fi
            if [ "${GUEST_STATUS}" != "$5" ] && [[ "${GUEST_STATUS}" == failed:* ]]; then
                printf 'The database host reported failed startup status %s.\n' "${GUEST_STATUS}" >&2
                exit 70
            fi
            if [ "${GUEST_STATUS}" != "$5" ] && [[ "${GUEST_STATUS}" == "${expected_prefix}"* ]]; then
                if [ "$4" = none ]; then
                    printf 'Database host reported the idle rollback state.\n'
                else
                    printf 'Database host reported healthy release %s.\n' "$4"
                fi
                exit 0
            fi

            # Guest attribute reads are limited to ten queries per minute.
            if [ "${attempt}" -lt 86 ]; then
                sleep 7
            fi
        done

        printf 'Database host readiness timed out; last status was %s.\n' "${GUEST_STATUS}" >&2
        exit 70
        ;;
    *) usage ;;
esac
