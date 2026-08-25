#!/bin/bash

# Applies the seven non-secret database release fields to the existing stateful
# MIG and permits exactly one disruptive action: restart the current VM.
# Usage: deploy-database-release.sh <project> <zone> <revision> <json-keys-image> <authentication-image> <json-keys-password-version> <authentication-password-version> <json-keys-backup-password-version> <authentication-backup-password-version>

set -euo pipefail

if [ "$#" -ne 9 ]; then
    printf 'Usage: %s <project> <zone> <revision> <json-keys-image> <authentication-image> <json-keys-password-version> <authentication-password-version> <json-keys-backup-password-version> <authentication-backup-password-version>\n' "$0" >&2
    exit 64
fi

WORKLOAD_PROJECT_ID="$1"
DATABASE_ZONE="$2"
RELEASE_REVISION="$3"
JSON_KEYS_IMAGE="$4"
AUTHENTICATION_IMAGE="$5"
JSON_KEYS_PASSWORD_VERSION="$6"
AUTHENTICATION_PASSWORD_VERSION="$7"
JSON_KEYS_BACKUP_PASSWORD_VERSION="$8"
AUTHENTICATION_BACKUP_PASSWORD_VERSION="$9"
DATABASE_GROUP="agora-database"
DATABASE_REGION="${DATABASE_ZONE%-*}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

require_positive_integer() {
    if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
        printf 'Invalid %s.\n' "$1" >&2
        exit 65
    fi
}

require_promoted_image() {
    local label="$1"
    local image="$2"
    local repository="$3"
    local prefix="${DATABASE_REGION}-docker.pkg.dev/${WORKLOAD_PROJECT_ID}/agora-production/${repository}@sha256:"
    local digest=""

    case "${image}" in
        "${prefix}"*) digest="${image#"${prefix}"}" ;;
        *)
            printf 'Invalid promoted %s image.\n' "${label}" >&2
            exit 65
            ;;
    esac

    if ! [[ "${digest}" =~ ^[a-f0-9]{64}$ ]]; then
        printf 'Invalid promoted %s image.\n' "${label}" >&2
        exit 65
    fi
}

if ! [[ "${WORKLOAD_PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
    printf 'Invalid workload project ID.\n' >&2
    exit 65
fi

if ! [[ "${DATABASE_ZONE}" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]]; then
    printf 'Invalid database zone.\n' >&2
    exit 65
fi

if ! [[ "${RELEASE_REVISION}" =~ ^[a-f0-9]{40}$ ]]; then
    printf 'Invalid release revision.\n' >&2
    exit 65
fi

require_positive_integer 'JSON Keys password version' "${JSON_KEYS_PASSWORD_VERSION}"
require_positive_integer 'Authentication password version' "${AUTHENTICATION_PASSWORD_VERSION}"
require_positive_integer 'JSON Keys backup password version' "${JSON_KEYS_BACKUP_PASSWORD_VERSION}"
require_positive_integer 'Authentication backup password version' "${AUTHENTICATION_BACKUP_PASSWORD_VERSION}"
require_promoted_image 'JSON Keys' "${JSON_KEYS_IMAGE}" 'service-json-keys/database'
require_promoted_image 'Authentication' "${AUTHENTICATION_IMAGE}" 'service-authentication/database'

if ! command -v gcloud >/dev/null 2>&1; then
    printf 'Google Cloud CLI is required by the protected deployment environment.\n' >&2
    exit 69
fi

# This shared gate is also mandatory before migrations. It checks foundation's
# seven-key metadata boundary, a ready scheduled snapshot no older than six
# hours, and fresh logical backups before this helper can mutate the MIG.
"${SCRIPT_DIR}/prepare-database-change.sh" \
    "${WORKLOAD_PROJECT_ID}" \
    "${DATABASE_ZONE}" \
    "${RELEASE_REVISION}"

# The group's OPPORTUNISTIC policy ensures allInstancesConfig acts only on new
# members by itself. The second command is therefore mandatory and caps the
# existing member's action at RESTART: a pending template or disk change that
# would require replacement fails closed.
gcloud compute instance-groups managed all-instances-config update "${DATABASE_GROUP}" \
    --project="${WORKLOAD_PROJECT_ID}" \
    --zone="${DATABASE_ZONE}" \
    --metadata="agora-database-release-revision=${RELEASE_REVISION},agora-json-keys-database-image=${JSON_KEYS_IMAGE},agora-authentication-database-image=${AUTHENTICATION_IMAGE},agora-json-keys-postgres-password-version=${JSON_KEYS_PASSWORD_VERSION},agora-authentication-postgres-password-version=${AUTHENTICATION_PASSWORD_VERSION},agora-json-keys-postgres-backup-password-version=${JSON_KEYS_BACKUP_PASSWORD_VERSION},agora-authentication-postgres-backup-password-version=${AUTHENTICATION_BACKUP_PASSWORD_VERSION}" \
    --quiet

gcloud compute instance-groups managed update-instances "${DATABASE_GROUP}" \
    --project="${WORKLOAD_PROJECT_ID}" \
    --zone="${DATABASE_ZONE}" \
    --all-instances \
    --minimal-action=restart \
    --most-disruptive-allowed-action=restart \
    --quiet

printf 'Database release metadata was applied; readiness still requires the protected health gate.\n'
