#!/bin/bash

# Applies the five non-secret database release fields to the existing stateful
# MIG and permits exactly one disruptive action: restart the current VM.
# Usage: deploy-database-release.sh <project> <zone> <revision> <json-keys-image> <authentication-image> <json-keys-password-version> <authentication-password-version>

set -euo pipefail

if [ "$#" -ne 7 ]; then
    printf 'Usage: %s <project> <zone> <revision> <json-keys-image> <authentication-image> <json-keys-password-version> <authentication-password-version>\n' "$0" >&2
    exit 64
fi

WORKLOAD_PROJECT_ID="$1"
DATABASE_ZONE="$2"
RELEASE_REVISION="$3"
JSON_KEYS_IMAGE="$4"
AUTHENTICATION_IMAGE="$5"
JSON_KEYS_PASSWORD_VERSION="$6"
AUTHENTICATION_PASSWORD_VERSION="$7"
DATABASE_GROUP="agora-database"
DATABASE_REGION="${DATABASE_ZONE%-*}"

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
require_promoted_image 'JSON Keys' "${JSON_KEYS_IMAGE}" 'service-json-keys/database'
require_promoted_image 'Authentication' "${AUTHENTICATION_IMAGE}" 'service-authentication/database'

if ! command -v gcloud >/dev/null 2>&1; then
    printf 'Google Cloud CLI is required by the protected deployment environment.\n' >&2
    exit 69
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is required by the protected deployment environment.\n' >&2
    exit 69
fi

# Foundation owns the map shape while release owns its five values. Refuse to
# merge into an unknown key because foundation deliberately ignores value drift
# on this one MIG field.
if ! gcloud compute instance-groups managed describe "${DATABASE_GROUP}" \
        --project="${WORKLOAD_PROJECT_ID}" \
        --zone="${DATABASE_ZONE}" \
        --format='json(allInstancesConfig.properties.metadata)' \
        | jq --exit-status '
            (.allInstancesConfig.properties.metadata // {} | keys) == [
                "agora-authentication-database-image",
                "agora-authentication-postgres-password-version",
                "agora-database-release-revision",
                "agora-json-keys-database-image",
                "agora-json-keys-postgres-password-version"
            ]
        ' >/dev/null; then
    printf 'Database release metadata shape differs from the reviewed five-key contract.\n' >&2
    exit 70
fi

# The group's OPPORTUNISTIC policy ensures allInstancesConfig acts only on new
# members by itself. The second command is therefore mandatory and caps the
# existing member's action at RESTART: a pending template or disk change that
# would require replacement fails closed.
gcloud compute instance-groups managed all-instances-config update "${DATABASE_GROUP}" \
    --project="${WORKLOAD_PROJECT_ID}" \
    --zone="${DATABASE_ZONE}" \
    --metadata="agora-database-release-revision=${RELEASE_REVISION},agora-json-keys-database-image=${JSON_KEYS_IMAGE},agora-authentication-database-image=${AUTHENTICATION_IMAGE},agora-json-keys-postgres-password-version=${JSON_KEYS_PASSWORD_VERSION},agora-authentication-postgres-password-version=${AUTHENTICATION_PASSWORD_VERSION}" \
    --quiet

gcloud compute instance-groups managed update-instances "${DATABASE_GROUP}" \
    --project="${WORKLOAD_PROJECT_ID}" \
    --zone="${DATABASE_ZONE}" \
    --all-instances \
    --minimal-action=restart \
    --most-disruptive-allowed-action=restart \
    --quiet

printf 'Database release metadata was applied; readiness still requires the protected health gate.\n'
