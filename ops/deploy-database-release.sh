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

# The protected orchestrator runs the shared gate before any mutation. Direct
# operator use still runs it here. A proof is short-lived, exact, private local
# workflow state; it is not an authorization credential.
if [ -n "${DATABASE_CHANGE_PROOF:-}" ]; then
    NOW_EPOCH="$(date -u +%s)"
    if ! jq --exit-status \
        --arg project "${WORKLOAD_PROJECT_ID}" \
        --arg zone "${DATABASE_ZONE}" \
        --arg revision "${RELEASE_REVISION}" \
        --argjson now "${NOW_EPOCH}" '
          type == "object" and
          keys == ["checkedAt", "currentMetadataSha256", "project", "revision", "zone"] and
          .project == $project and
          .zone == $zone and
          .revision == $revision and
          (.currentMetadataSha256 | test("^[a-f0-9]{64}$")) and
          (.checkedAt | type == "number") and
          .checkedAt <= ($now + 30) and
          .checkedAt >= ($now - 600)
        ' "${DATABASE_CHANGE_PROOF}" >/dev/null; then
        printf 'The database change preflight proof is invalid or stale.\n' >&2
        exit 70
    fi
else
    "${SCRIPT_DIR}/prepare-database-change.sh" \
        "${WORKLOAD_PROJECT_ID}" \
        "${DATABASE_ZONE}" \
        "${RELEASE_REVISION}"
fi

if ! DATABASE_STATUS_BEFORE="$(
    "${SCRIPT_DIR}/database-host-readiness.sh" current \
        "${WORKLOAD_PROJECT_ID}" \
        "${DATABASE_ZONE}"
)"; then
    printf 'Database host readiness could not be inspected before restart.\n' >&2
    exit 70
fi

# The group's OPPORTUNISTIC policy ensures allInstancesConfig acts only on new
# members by itself. The second command is therefore mandatory and caps the
# existing member's action at RESTART: a pending template or disk change that
# would require replacement fails closed.
if ! gcloud compute instance-groups managed all-instances-config update "${DATABASE_GROUP}" \
    --project="${WORKLOAD_PROJECT_ID}" \
    --zone="${DATABASE_ZONE}" \
    --metadata="agora-database-release-revision=${RELEASE_REVISION},agora-json-keys-database-image=${JSON_KEYS_IMAGE},agora-authentication-database-image=${AUTHENTICATION_IMAGE},agora-json-keys-postgres-password-version=${JSON_KEYS_PASSWORD_VERSION},agora-authentication-postgres-password-version=${AUTHENTICATION_PASSWORD_VERSION},agora-json-keys-postgres-backup-password-version=${JSON_KEYS_BACKUP_PASSWORD_VERSION},agora-authentication-postgres-backup-password-version=${AUTHENTICATION_BACKUP_PASSWORD_VERSION}" \
    --quiet >/dev/null 2>&1; then
    printf 'Database release metadata could not be updated.\n' >&2
    exit 70
fi

if ! gcloud compute instance-groups managed update-instances "${DATABASE_GROUP}" \
    --project="${WORKLOAD_PROJECT_ID}" \
    --zone="${DATABASE_ZONE}" \
    --all-instances \
    --minimal-action=restart \
    --most-disruptive-allowed-action=restart \
    --quiet >/dev/null 2>&1; then
    printf 'The bounded database restart could not be requested.\n' >&2
    exit 70
fi

# Compute accepts an update request before the singleton has necessarily
# completed its restart. Do not start migrations while the MIG is still moving.
if ! gcloud compute instance-groups managed wait-until "${DATABASE_GROUP}" \
    --project="${WORKLOAD_PROJECT_ID}" \
    --zone="${DATABASE_ZONE}" \
    --stable \
    --timeout=600 \
    --quiet >/dev/null 2>&1; then
    printf 'The database host did not become stable after its restart.\n' >&2
    exit 70
fi

if ! "${SCRIPT_DIR}/database-host-readiness.sh" wait \
    "${WORKLOAD_PROJECT_ID}" \
    "${DATABASE_ZONE}" \
    "${RELEASE_REVISION}" \
    "${DATABASE_STATUS_BEFORE}"; then
    printf 'The database host did not report a healthy release after restart.\n' >&2
    exit 70
fi

printf 'Database release metadata was applied and the host is healthy.\n'
