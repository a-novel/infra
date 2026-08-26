#!/bin/bash

# Restore only the prior receipt's seven non-secret database metadata fields.
# A null prior release returns the first-launch host to its empty state. Data on
# the preserved disk is never reversed or restored automatically.
# Usage: restore-database-release.sh <project> <zone> <previous-database.json>

set -euo pipefail

if [ "$#" -ne 3 ]; then
    printf 'Usage: %s <project> <zone> <previous-database.json>\n' "$0" >&2
    exit 64
fi

PROJECT_ID="$1"
DATABASE_ZONE="$2"
DATABASE_FILE="$3"
DATABASE_GROUP="agora-database"

if ! [[ "${PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    ! [[ "${DATABASE_ZONE}" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]] ||
    [ ! -f "${DATABASE_FILE}" ]; then
    printf 'Invalid database rollback input.\n' >&2
    exit 65
fi

if jq --exit-status '. == null' "${DATABASE_FILE}" >/dev/null; then
    RELEASE_REVISION=""
    JSON_KEYS_IMAGE=""
    AUTHENTICATION_IMAGE=""
    JSON_KEYS_PASSWORD_VERSION=0
    AUTHENTICATION_PASSWORD_VERSION=0
    JSON_KEYS_BACKUP_PASSWORD_VERSION=0
    AUTHENTICATION_BACKUP_PASSWORD_VERSION=0
elif jq --exit-status '
    type == "object" and
    keys == [
      "authenticationBackupPasswordVersion",
      "authenticationImage",
      "authenticationPasswordVersion",
      "jsonKeysBackupPasswordVersion",
      "jsonKeysImage",
      "jsonKeysPasswordVersion",
      "releaseRevision"
    ] and
    (.releaseRevision | test("^[a-f0-9]{40}$")) and
    (.jsonKeysImage | test("/service-json-keys/database@sha256:[a-f0-9]{64}$")) and
    (.authenticationImage | test("/service-authentication/database@sha256:[a-f0-9]{64}$")) and
    all([
      .jsonKeysPasswordVersion,
      .authenticationPasswordVersion,
      .jsonKeysBackupPasswordVersion,
      .authenticationBackupPasswordVersion
    ][]; type == "number" and . >= 1 and floor == .)
' "${DATABASE_FILE}" >/dev/null; then
    RELEASE_REVISION="$(jq --raw-output '.releaseRevision' "${DATABASE_FILE}")"
    JSON_KEYS_IMAGE="$(jq --raw-output '.jsonKeysImage' "${DATABASE_FILE}")"
    AUTHENTICATION_IMAGE="$(jq --raw-output '.authenticationImage' "${DATABASE_FILE}")"
    JSON_KEYS_PASSWORD_VERSION="$(jq --raw-output '.jsonKeysPasswordVersion' "${DATABASE_FILE}")"
    AUTHENTICATION_PASSWORD_VERSION="$(jq --raw-output '.authenticationPasswordVersion' "${DATABASE_FILE}")"
    JSON_KEYS_BACKUP_PASSWORD_VERSION="$(jq --raw-output '.jsonKeysBackupPasswordVersion' "${DATABASE_FILE}")"
    AUTHENTICATION_BACKUP_PASSWORD_VERSION="$(jq --raw-output '.authenticationBackupPasswordVersion' "${DATABASE_FILE}")"
else
    printf 'Previous database receipt is invalid.\n' >&2
    exit 65
fi

if ! gcloud compute instance-groups managed all-instances-config update "${DATABASE_GROUP}" \
    --project="${PROJECT_ID}" \
    --zone="${DATABASE_ZONE}" \
    --metadata="agora-database-release-revision=${RELEASE_REVISION},agora-json-keys-database-image=${JSON_KEYS_IMAGE},agora-authentication-database-image=${AUTHENTICATION_IMAGE},agora-json-keys-postgres-password-version=${JSON_KEYS_PASSWORD_VERSION},agora-authentication-postgres-password-version=${AUTHENTICATION_PASSWORD_VERSION},agora-json-keys-postgres-backup-password-version=${JSON_KEYS_BACKUP_PASSWORD_VERSION},agora-authentication-postgres-backup-password-version=${AUTHENTICATION_BACKUP_PASSWORD_VERSION}" \
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

printf 'Database release metadata restored from the prior immutable receipt.\n'
