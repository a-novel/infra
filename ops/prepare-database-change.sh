#!/bin/bash

# Fails closed unless the selected disk snapshot is fresh and its database
# has just published a validated logical backup. The initial empty
# host has no database contents to dump, so only its snapshot gate applies.
# Usage: prepare-database-change.sh <project> <zone> <service> <data-disk-id> <change-revision> [proof-file] [expected-current-metadata-sha256]

set -euo pipefail

if [ "$#" -lt 5 ] || [ "$#" -gt 7 ]; then
    printf 'Usage: %s <project> <zone> <service> <data-disk-id> <change-revision> [proof-file] [expected-current-metadata-sha256]\n' "$0" >&2
    exit 64
fi

WORKLOAD_PROJECT_ID="$1"
DATABASE_ZONE="$2"
DATABASE_SERVICE="$3"
DATA_DISK_ID="$4"
CHANGE_REVISION="$5"
PROOF_FILE="${6:-}"
EXPECTED_CURRENT_METADATA_SHA256="${7:-}"
DATABASE_GROUP="agora-database-${DATABASE_SERVICE}"
DATABASE_DISK="agora-data-${DATABASE_SERVICE}"
DATABASE_REGION="${DATABASE_ZONE%-*}"

if ! [[ "${WORKLOAD_PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    ! [[ "${DATABASE_ZONE}" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]] ||
    ! [[ "${CHANGE_REVISION}" =~ ^[a-f0-9]{40}$ ]] ||
    ! [[ "${DATA_DISK_ID}" =~ ^[1-9][0-9]*$ ]] ||
    { [ "${DATABASE_SERVICE}" != authentication ] && [ "${DATABASE_SERVICE}" != json-keys ]; } ||
    { [ -n "${EXPECTED_CURRENT_METADATA_SHA256}" ] &&
        ! [[ "${EXPECTED_CURRENT_METADATA_SHA256}" =~ ^[a-f0-9]{64}$ ]]; }; then
    printf 'Invalid database change gate input.\n' >&2
    exit 65
fi

if ! command -v gcloud >/dev/null 2>&1; then
    printf 'Google Cloud CLI is required by the protected deployment environment.\n' >&2
    exit 69
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is required by the protected deployment environment.\n' >&2
    exit 69
fi

if ! command -v sha256sum >/dev/null 2>&1; then
    printf 'sha256sum is required by the protected deployment environment.\n' >&2
    exit 69
fi

# The exact map shape is the shared boundary between foundation and release.
# Hash the complete prior map without printing it; images and secret-version
# IDs never enter a public workflow log.
EXPECTED_METADATA_KEYS="$(jq -nc --arg service "${DATABASE_SERVICE}" '[
  "agora-\($service)-database-image",
  "agora-\($service)-postgres-backup-password-version",
  "agora-\($service)-postgres-password-version",
  "agora-database-release-revision"
] | sort')"

CURRENT_DATA_DISK_ID="$(gcloud compute disks describe "${DATABASE_DISK}" --project="${WORKLOAD_PROJECT_ID}" --zone="${DATABASE_ZONE}" --format='value(id)')"
if [ "${CURRENT_DATA_DISK_ID}" != "${DATA_DISK_ID}" ]; then
    printf 'The selected database disk differs from the protected release configuration.\n' >&2
    exit 70
fi

if ! DATABASE_GROUP_JSON="$(
    gcloud compute instance-groups managed describe "${DATABASE_GROUP}" \
        --project="${WORKLOAD_PROJECT_ID}" \
        --zone="${DATABASE_ZONE}" \
        --format=json
)"; then
    printf 'Database release metadata could not be inspected.\n' >&2
    exit 70
fi

if ! CURRENT_METADATA="$(
    jq --compact-output --exit-status --sort-keys \
        --argjson expected "${EXPECTED_METADATA_KEYS}" '
          (.allInstancesConfig.properties.metadata // null) as $metadata
          | if ($metadata | type) != "object"
            then error({
              missing: $expected,
              unexpected: [],
              metadataType: ($metadata | type)
            })
            else ($metadata | keys) as $actual
              | if $actual == $expected
                then $metadata
                else error({
                  missing: ($expected - $actual),
                  unexpected: ($actual - $expected)
                })
                end
            end
        ' <<<"${DATABASE_GROUP_JSON}"
)"; then
    printf 'Database release metadata shape differs from the reviewed four-key contract.\n' >&2
    exit 70
fi
unset DATABASE_GROUP_JSON EXPECTED_METADATA_KEYS

CURRENT_RELEASE_REVISION="$(
    jq --raw-output '.["agora-database-release-revision"]' <<<"${CURRENT_METADATA}"
)"
CURRENT_METADATA_SHA256="$(
    printf '%s' "${CURRENT_METADATA}" | sha256sum | cut -d ' ' -f 1
)"

if [ -n "${EXPECTED_CURRENT_METADATA_SHA256}" ] &&
    [ "${CURRENT_METADATA_SHA256}" != "${EXPECTED_CURRENT_METADATA_SHA256}" ]; then
    printf 'Current database release metadata differs from the latest immutable receipt.\n' >&2
    exit 70
fi

if [ -n "${CURRENT_RELEASE_REVISION}" ] &&
    ! [[ "${CURRENT_RELEASE_REVISION}" =~ ^[a-f0-9]{40}$ ]]; then
    printf 'Current database release revision is invalid.\n' >&2
    exit 70
fi

# The release identity can list snapshot metadata but cannot create or delete a
# snapshot. This keeps the seven-day foundation schedule as the only lifecycle.
if ! SNAPSHOT_CREATED="$(
    gcloud compute snapshots list \
        --project="${WORKLOAD_PROJECT_ID}" \
        --filter="labels.application=agora AND labels.environment=production AND labels.role=database-snapshot AND labels.component=${DATABASE_SERVICE}" \
        --sort-by='~creationTimestamp' \
        --limit=1 \
        --format='json(name,autoCreated,sourceDisk,sourceDiskId,status,creationTimestamp,storageLocations,labels)' \
        2>/dev/null \
        | jq --exit-status --raw-output \
            --arg source_suffix "/projects/${WORKLOAD_PROJECT_ID}/zones/${DATABASE_ZONE}/disks/${DATABASE_DISK}" \
            --arg disk_id "${DATA_DISK_ID}" \
            --arg service "${DATABASE_SERVICE}" \
            --arg storage_location "${DATABASE_REGION}" '
                if length == 1
                   and .[0].autoCreated == true
                   and .[0].status == "READY"
                   and (.[0].sourceDisk | endswith($source_suffix))
                   and (.[0].sourceDiskId | tostring) == $disk_id
                   and .[0].labels.component == $service
                   and .[0].labels.application == "agora"
                   and .[0].labels.environment == "production"
                   and .[0].labels["managed-by"] == "opentofu"
                   and .[0].labels.plane == "workload"
                   and .[0].labels.role == "database-snapshot"
                   and (.[0].storageLocations | index($storage_location)) != null
                then .[0].creationTimestamp
                else error("no valid database snapshot")
                end
            '
)"; then
    printf 'No valid scheduled database snapshot is ready.\n' >&2
    exit 70
fi

if ! SNAPSHOT_EPOCH="$(date -u --date="${SNAPSHOT_CREATED}" +%s 2>/dev/null)"; then
    printf 'The scheduled database snapshot timestamp is invalid.\n' >&2
    exit 70
fi
NOW_EPOCH="$(date -u +%s)"
SNAPSHOT_AGE_SECONDS=$((NOW_EPOCH - SNAPSHOT_EPOCH))
if [ "${SNAPSHOT_AGE_SECONDS}" -lt -300 ] || [ "${SNAPSHOT_AGE_SECONDS}" -gt 93600 ]; then
    printf 'The latest scheduled database snapshot is outside the 26-hour daily change window.\n' >&2
    exit 70
fi

if [ -z "${CURRENT_RELEASE_REVISION}" ]; then
    if [ -n "${PROOF_FILE}" ]; then
        jq -n \
            --arg project "${WORKLOAD_PROJECT_ID}" \
            --arg zone "${DATABASE_ZONE}" \
            --arg service "${DATABASE_SERVICE}" \
            --arg disk_id "${DATA_DISK_ID}" \
            --arg revision "${CHANGE_REVISION}" \
            --arg current_metadata_sha256 "${CURRENT_METADATA_SHA256}" \
            --argjson checked_at "$(date -u +%s)" \
            '{project: $project, zone: $zone, service: $service, dataDiskId: $disk_id, revision: $revision, currentMetadataSha256: $current_metadata_sha256, checkedAt: $checked_at}' \
            >"${PROOF_FILE}"
        chmod 600 "${PROOF_FILE}"
    fi
    printf 'Database change gate passed for an empty first release; no source database exists to dump.\n'
    exit 0
fi

if ! gcloud run jobs execute "agora-postgres-backup-${DATABASE_SERVICE}" \
    --project="${WORKLOAD_PROJECT_ID}" \
    --region="${DATABASE_REGION}" \
    --wait \
    --quiet \
    --format=none \
    >/dev/null 2>&1; then
    printf 'A required pre-change PostgreSQL backup failed.\n' >&2
    exit 70
fi

if [ -n "${PROOF_FILE}" ]; then
    jq -n \
        --arg project "${WORKLOAD_PROJECT_ID}" \
        --arg zone "${DATABASE_ZONE}" \
        --arg service "${DATABASE_SERVICE}" \
        --arg disk_id "${DATA_DISK_ID}" \
        --arg revision "${CHANGE_REVISION}" \
        --arg current_metadata_sha256 "${CURRENT_METADATA_SHA256}" \
        --argjson checked_at "$(date -u +%s)" \
        '{project: $project, zone: $zone, service: $service, dataDiskId: $disk_id, revision: $revision, currentMetadataSha256: $current_metadata_sha256, checkedAt: $checked_at}' \
        >"${PROOF_FILE}"
    chmod 600 "${PROOF_FILE}"
fi

printf 'Database change gate passed: snapshot and logical backups are fresh.\n'
