#!/bin/bash

# Adds human-supplied payloads to declared production secrets and prints their numeric versions.
# Usage: ./ops/add-secret-version.sh <secret-id> [<secret-id> ...]

set -euo pipefail
set +x
umask 077

if [ "$#" -lt 1 ]; then
    printf 'Usage: %s <secret-id> [<secret-id> ...]\n' "$0" >&2
    exit 64
fi

is_declared_secret() {
    case "$1" in
        production-authentication-postgres-dsn | \
            production-authentication-postgres-password | \
            production-authentication-postgres-backup-password | \
            production-authentication-smtp-sender-password | \
            production-authentication-super-admin-password | \
            production-json-keys-app-master-key | \
            production-json-keys-postgres-dsn | \
            production-json-keys-postgres-password | \
            production-json-keys-postgres-backup-password) return 0 ;;
        *) return 1 ;;
    esac
}

SEEN_SECRET_IDS=""
for secret_id in "$@"; do
    if ! is_declared_secret "${secret_id}"; then
        printf 'Refusing undeclared secret ID: %s.\n' "${secret_id}" >&2
        exit 65
    fi
    case ":${SEEN_SECRET_IDS}:" in
        *":${secret_id}:"*)
            printf 'Refusing duplicate secret ID: %s.\n' "${secret_id}" >&2
            exit 65
            ;;
    esac
    SEEN_SECRET_IDS="${SEEN_SECRET_IDS:+${SEEN_SECRET_IDS}:}${secret_id}"
done
unset SEEN_SECRET_IDS

for command_name in gh gcloud; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required.\n' "${command_name}" >&2
        exit 69
    fi
done

MANAGEMENT_PROJECT_ID="$(gh variable get GCP_MANAGEMENT_PROJECT_ID --repo a-novel/infra)"
if ! [[ "${MANAGEMENT_PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
    printf 'GCP_MANAGEMENT_PROJECT_ID is missing or invalid.\n' >&2
    exit 65
fi

for secret_id in "$@"; do
    gcloud secrets describe "${secret_id}" \
        --project="${MANAGEMENT_PROJECT_ID}" \
        --format='yaml(name,annotations,createTime,versionDestroyTtl)' >&2
done

add_secret_version() {
    local secret_id="$1"
    local secret_value secret_value_confirmation version_id version_state

    printf '%s value: ' "${secret_id}" >&2
    if ! IFS= read -r -s secret_value; then
        printf '\nInput ended before a value was read.\n' >&2
        return 65
    fi
    printf '\nRepeat %s value: ' "${secret_id}" >&2
    if ! IFS= read -r -s secret_value_confirmation; then
        printf '\nInput ended before the repeated value was read.\n' >&2
        return 65
    fi
    printf '\n' >&2
    if [ -z "${secret_value}" ] || [ "${secret_value}" != "${secret_value_confirmation}" ]; then
        printf 'Secret values are empty or do not match.\n' >&2
        return 65
    fi

    case "${secret_id}" in
        production-authentication-postgres-password | \
            production-authentication-postgres-backup-password | \
            production-json-keys-postgres-password | \
            production-json-keys-postgres-backup-password)
            if [ "${#secret_value}" -lt 32 ] || [ "${#secret_value}" -gt 128 ] || \
                ! [[ "${secret_value}" =~ ^[A-Za-z0-9_-]+$ ]]; then
                printf 'PostgreSQL passwords require 32-128 URL-safe characters.\n' >&2
                return 65
            fi
            ;;
    esac

    version_id="$(
        printf '%s' "${secret_value}" \
            | gcloud secrets versions add "${secret_id}" \
                --project="${MANAGEMENT_PROJECT_ID}" \
                --data-file=- \
                --quiet \
                --format='value(name.basename())'
    )"
    unset secret_value secret_value_confirmation

    if ! [[ "${version_id}" =~ ^[1-9][0-9]*$ ]]; then
        printf 'Secret Manager did not return a numeric version.\n' >&2
        return 70
    fi

    version_state="$(gcloud secrets versions describe "${version_id}" \
        --secret="${secret_id}" \
        --project="${MANAGEMENT_PROJECT_ID}" \
        --format='value(state)')"
    if [ "${version_state}" != ENABLED ]; then
        printf 'The new secret version is not enabled.\n' >&2
        return 70
    fi

    gcloud secrets versions describe "${version_id}" \
        --secret="${secret_id}" \
        --project="${MANAGEMENT_PROJECT_ID}" \
        --format='yaml(name,state,createTime,destroyTime,scheduledDestroyTime)' >&2

    printf 'Created %s version %s.\n' "${secret_id}" "${version_id}"
}

for secret_id in "$@"; do
    add_secret_version "${secret_id}"
done
