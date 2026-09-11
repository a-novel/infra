#!/bin/bash

# Restore only the prior receipt's selected host's non-secret database metadata fields.
# A null prior release returns the first-launch host to its empty state. Data on
# the preserved disk is never reversed or restored automatically.
# Usage: restore-database-release.sh <project> <zone> <service> <data-disk-id> <previous-database.json>

set -euo pipefail

if [ "$#" -ne 5 ]; then
    printf 'Usage: %s <project> <zone> <service> <data-disk-id> <previous-database.json>\n' "$0" >&2
    exit 64
fi

PROJECT_ID="$1"
DATABASE_ZONE="$2"
DATABASE_SERVICE="$3"
DATA_DISK_ID="$4"
DATABASE_FILE="$5"
DATABASE_GROUP="agora-database-${DATABASE_SERVICE}"
SERVICE_KEY="${DATABASE_SERVICE//-/_}"
DATABASE_REGION="${DATABASE_ZONE%-*}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! [[ "${PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    ! [[ "${DATABASE_ZONE}" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]] ||
    ! [[ "${DATA_DISK_ID}" =~ ^[1-9][0-9]*$ ]] ||
    { [ "${DATABASE_SERVICE}" != authentication ] && [ "${DATABASE_SERVICE}" != json-keys ]; } ||
    [ ! -f "${DATABASE_FILE}" ]; then
    printf 'Invalid database rollback input.\n' >&2
    exit 65
fi

if ! jq -e --arg service "${SERVICE_KEY}" --arg disk_id "${DATA_DISK_ID}" --arg prefix "${DATABASE_REGION}-docker.pkg.dev/${PROJECT_ID}/agora-production/service-${DATABASE_SERVICE}/database@sha256:" '
    . == null or (
      (if $service == "json_keys" then "jsonKeys" else "authentication" end) as $key |
      .hosts[$service].dataDiskId == $disk_id and
      (.hosts[$service].releaseRevision | test("^[a-f0-9]{40}$")) and
      (.[$key + "Image"] | startswith($prefix)) and
      (.[$key + "Image"] | ltrimstr($prefix) | test("^[a-f0-9]{64}$")) and
      all([.[$key + "PasswordVersion"], .[$key + "BackupPasswordVersion"]][];
        type == "number" and . >= 1 and floor == .)
    )
' "${DATABASE_FILE}" >/dev/null; then
    printf 'Receipt does not identify this exact database disk and image family.\n' >&2
    exit 65
fi
if [ "$(gcloud compute disks describe "agora-data-${DATABASE_SERVICE}" --project="${PROJECT_ID}" --zone="${DATABASE_ZONE}" --format='value(id)')" != "${DATA_DISK_ID}" ]; then
    printf 'Live database disk differs from the rollback target.\n' >&2
    exit 70
fi
RELEASE_REVISION="$(jq -r --arg service "${SERVICE_KEY}" '.hosts[$service].releaseRevision // ""' "${DATABASE_FILE}")"
METADATA_ARGUMENT="$(jq -r --arg service "${DATABASE_SERVICE}" --arg key "${SERVICE_KEY}" '
    . as $database |
    (if $key == "json_keys" then "jsonKeys" else "authentication" end) as $prefix |
    {
      "agora-database-release-revision": ($database.hosts[$key].releaseRevision // ""),
      ("agora-\($service)-database-image"): ($database[$prefix + "Image"] // ""),
      ("agora-\($service)-postgres-password-version"): (($database[$prefix + "PasswordVersion"] // 0) | tostring),
      ("agora-\($service)-postgres-backup-password-version"): (($database[$prefix + "BackupPasswordVersion"] // 0) | tostring)
    } | to_entries | map(.key + "=" + .value) | join(",")
' "${DATABASE_FILE}")"

if ! DATABASE_STATUS_BEFORE="$(
    "${SCRIPT_DIR}/database-host-readiness.sh" current \
        "${PROJECT_ID}" \
        "${DATABASE_ZONE}" \
        "${DATABASE_SERVICE}"
)"; then
    printf 'Database host readiness could not be inspected before rollback.\n' >&2
    exit 70
fi

if ! gcloud compute instance-groups managed all-instances-config update "${DATABASE_GROUP}" \
    --project="${PROJECT_ID}" \
    --zone="${DATABASE_ZONE}" \
    --metadata="${METADATA_ARGUMENT}" \
    --quiet >/dev/null 2>&1; then
    printf 'Prior database release metadata could not be restored.\n' >&2
    exit 70
fi

if ! gcloud compute instance-groups managed update-instances "${DATABASE_GROUP}" \
    --project="${PROJECT_ID}" \
    --zone="${DATABASE_ZONE}" \
    --all-instances \
    --minimal-action=restart \
    --most-disruptive-allowed-action=restart \
    --quiet >/dev/null 2>&1; then
    printf 'The bounded database rollback restart could not be requested.\n' >&2
    exit 70
fi

if ! gcloud compute instance-groups managed wait-until "${DATABASE_GROUP}" \
    --project="${PROJECT_ID}" \
    --zone="${DATABASE_ZONE}" \
    --stable \
    --timeout=600 \
    --quiet >/dev/null 2>&1; then
    printf 'The database host did not become stable after rollback.\n' >&2
    exit 70
fi

if [ -z "${RELEASE_REVISION}" ]; then
    EXPECTED_DATABASE_STATUS="none"
else
    EXPECTED_DATABASE_STATUS="${RELEASE_REVISION}"
fi

if ! "${SCRIPT_DIR}/database-host-readiness.sh" wait \
    "${PROJECT_ID}" \
    "${DATABASE_ZONE}" \
    "${DATABASE_SERVICE}" \
    "${EXPECTED_DATABASE_STATUS}" \
    "${DATABASE_STATUS_BEFORE}"; then
    printf 'The database host did not report the restored release after rollback.\n' >&2
    exit 70
fi

printf 'Database release metadata restored from the prior immutable receipt.\n'
