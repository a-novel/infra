#!/bin/bash

# Applies one service's pinned release metadata and restarts only its existing VM.
# Usage: deploy-database-release.sh <project> <zone> <service> <data-disk-id> <revision> <image> <password-version> <backup-password-version>

set -euo pipefail

if [ "$#" -ne 8 ]; then
    printf 'Usage: %s <project> <zone> <service> <data-disk-id> <revision> <image> <password-version> <backup-password-version>\n' "$0" >&2
    exit 64
fi

WORKLOAD_PROJECT_ID="$1"
DATABASE_ZONE="$2"
DATABASE_SERVICE="$3"
DATA_DISK_ID="$4"
RELEASE_REVISION="$5"
DATABASE_IMAGE="$6"
PASSWORD_VERSION="$7"
BACKUP_PASSWORD_VERSION="$8"
DATABASE_GROUP="agora-database-${DATABASE_SERVICE}"
DATABASE_REGION="${DATABASE_ZONE%-*}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! [[ "${WORKLOAD_PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    ! [[ "${DATABASE_ZONE}" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]] ||
    ! [[ "${RELEASE_REVISION}" =~ ^[a-f0-9]{40}$ ]] ||
    ! [[ "${DATA_DISK_ID}" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "${PASSWORD_VERSION}" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "${BACKUP_PASSWORD_VERSION}" =~ ^[1-9][0-9]*$ ]] ||
    { [ "${DATABASE_SERVICE}" != authentication ] && [ "${DATABASE_SERVICE}" != json-keys ]; }; then
    printf 'Invalid service database deployment input.\n' >&2
    exit 65
fi

IMAGE_PREFIX="${DATABASE_REGION}-docker.pkg.dev/${WORKLOAD_PROJECT_ID}/agora-production/service-${DATABASE_SERVICE}/database@sha256:"
if [[ "${DATABASE_IMAGE}" != "${IMAGE_PREFIX}"* ]] ||
    ! [[ "${DATABASE_IMAGE#"${IMAGE_PREFIX}"}" =~ ^[a-f0-9]{64}$ ]]; then
    printf 'Invalid promoted database image.\n' >&2
    exit 65
fi

for command_name in gcloud jq sha256sum; do
    command -v "${command_name}" >/dev/null || { printf '%s is required.\n' "${command_name}" >&2; exit 69; }
done

# A cached proof belongs to one exact host and remains valid for ten minutes.
if [ -n "${DATABASE_CHANGE_PROOF:-}" ]; then
    if ! jq --exit-status \
        --arg project "${WORKLOAD_PROJECT_ID}" \
        --arg zone "${DATABASE_ZONE}" \
        --arg service "${DATABASE_SERVICE}" \
        --arg disk_id "${DATA_DISK_ID}" \
        --arg revision "${RELEASE_REVISION}" \
        --argjson now "$(date -u +%s)" '
          type == "object" and
          keys == ["checkedAt", "currentMetadataSha256", "dataDiskId", "project", "revision", "service", "zone"] and
          .project == $project and .zone == $zone and .service == $service and
          .dataDiskId == $disk_id and .revision == $revision and
          (.currentMetadataSha256 | test("^[a-f0-9]{64}$")) and
          (.checkedAt | type == "number") and
          .checkedAt <= ($now + 30) and .checkedAt >= ($now - 600)
        ' "${DATABASE_CHANGE_PROOF}" >/dev/null; then
        printf 'The database change preflight proof is invalid or stale.\n' >&2
        exit 70
    fi
    LIVE_METADATA_HASH="$(
        gcloud compute instance-groups managed describe "${DATABASE_GROUP}" \
            --project="${WORKLOAD_PROJECT_ID}" --zone="${DATABASE_ZONE}" --format=json |
            jq --join-output --compact-output --sort-keys '.allInstancesConfig.properties.metadata' |
            sha256sum | cut -d ' ' -f 1
    )"
    if [ "${LIVE_METADATA_HASH}" != "$(jq -r '.currentMetadataSha256' "${DATABASE_CHANGE_PROOF}")" ]; then
        printf 'Database metadata changed after the preflight proof.\n' >&2
        exit 70
    fi
else
    "${SCRIPT_DIR}/prepare-database-change.sh" "${WORKLOAD_PROJECT_ID}" "${DATABASE_ZONE}" "${DATABASE_SERVICE}" "${DATA_DISK_ID}" "${RELEASE_REVISION}"
fi

if [ "$(gcloud compute disks describe "agora-data-${DATABASE_SERVICE}" --project="${WORKLOAD_PROJECT_ID}" --zone="${DATABASE_ZONE}" --format='value(id)')" != "${DATA_DISK_ID}" ]; then
    printf 'The database data disk changed after preflight.\n' >&2
    exit 70
fi

if ! DATABASE_STATUS_BEFORE="$(
    "${SCRIPT_DIR}/database-host-readiness.sh" current \
        "${WORKLOAD_PROJECT_ID}" \
        "${DATABASE_ZONE}" \
        "${DATABASE_SERVICE}"
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
    --metadata="agora-database-release-revision=${RELEASE_REVISION},agora-${DATABASE_SERVICE}-database-image=${DATABASE_IMAGE},agora-${DATABASE_SERVICE}-postgres-password-version=${PASSWORD_VERSION},agora-${DATABASE_SERVICE}-postgres-backup-password-version=${BACKUP_PASSWORD_VERSION}" \
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
    "${DATABASE_SERVICE}" \
    "${RELEASE_REVISION}" \
    "${DATABASE_STATUS_BEFORE}"; then
    printf 'The database host did not report a healthy release after restart.\n' >&2
    exit 70
fi

printf 'Database release metadata was applied and the host is healthy.\n'
