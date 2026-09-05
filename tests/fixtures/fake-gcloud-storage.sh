#!/bin/bash

# Minimal filesystem-backed `gcloud storage` fake for custody tests.

set -euo pipefail

ROOT="${FAKE_GCS_ROOT:?}"

local_path() {
    printf '%s/%s\n' "${ROOT}" "${1#gs://}"
}

if [ "$1 $2 $3" = "storage objects list" ]; then
    if [ "${FAKE_GCS_LIST_FAILURE:-false}" = true ]; then
        exit 1
    fi
    PATTERN="$(local_path "${4%/**}")"
    if [ -d "${PATTERN}" ]; then
        while IFS= read -r object; do
            relative="${object#"${ROOT}/"}"
            case "${5:-}" in
                '--format=value(name)') printf '%s\n' "${relative#*/}" ;;
                --uri) printf 'https://storage.googleapis.com/storage/v1/b/%s/o/%s#123456\n' "${relative%%/*}" "${relative#*/}" ;;
                *) exit 99 ;;
            esac
        done < <(find "${PATTERN}" -type f | LC_ALL=C sort)
    fi
elif [ "$1 $2" = "storage cp" ]; then
    SOURCE="$3"
    DESTINATION="$4"
    if [[ "${SOURCE}" == gs://* ]]; then
        if [ "${FAKE_GCS_READ_FAILURE:-false}" = true ]; then exit 1; fi
        cp -- "$(local_path "${SOURCE}")" "${DESTINATION}"
    else
        TARGET="$(local_path "${DESTINATION}")"
        if [[ " $* " == *" --if-generation-match=0 "* ]] && [ -e "${TARGET}" ]; then
            exit 1
        fi
        mkdir -p -- "$(dirname -- "${TARGET}")"
        cp -- "${SOURCE}" "${TARGET}"
        if [ "${FAKE_GCS_LOST_UPLOAD_RESPONSE:-false}" = true ]; then
            exit 1
        fi
    fi
elif [ "$1 $2" = "storage rm" ]; then
    shift 2
    for object in "$@"; do
        if [[ "${object}" == --* ]]; then
            continue
        fi
        rm -- "$(local_path "${object}")"
    done
elif [ "$1 $2" = "storage ls" ]; then
    if [ "${FAKE_GCS_LIST_FAILURE:-false}" = true ]; then
        exit 1
    fi
    PATTERN="$(local_path "$3")"
    if [[ " $* " == *" --recursive "* ]]; then
        if [ -d "${PATTERN}" ]; then
            while IFS= read -r object; do
                printf 'gs://%s\n' "${object#"${ROOT}/"}"
            done < <(find "${PATTERN}" -type f | LC_ALL=C sort)
        fi
    else
        while IFS= read -r object; do
            printf 'gs://%s\n' "${object#"${ROOT}/"}"
        done < <(compgen -G "${PATTERN}" | LC_ALL=C sort)
    fi
else
    exit 1
fi
