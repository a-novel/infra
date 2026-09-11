#!/bin/bash

# Clear only release metadata left by an interrupted first production launch.
# Usage: recover-first-launch.sh <receipt-bucket> <project> <zone> <service> <data-disk-id> <failed-revision>

set -euo pipefail

if [ "$#" -ne 6 ]; then
    printf 'Usage: %s <receipt-bucket> <project> <zone> <service> <data-disk-id> <failed-revision>\n' "$0" >&2
    exit 64
fi

RECEIPT_BUCKET="$1"
PROJECT_ID="$2"
DATABASE_ZONE="$3"
DATABASE_SERVICE="$4"
DATA_DISK_ID="$5"
FAILED_REVISION="$6"
DATABASE_GROUP="agora-database-${DATABASE_SERVICE}"
DATABASE_REGION="${DATABASE_ZONE%-*}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RECEIPT_FILE=''
EMPTY_DATABASE_FILE=''

if ! [[ "$RECEIPT_BUCKET" =~ ^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$ ]] ||
    ! [[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    ! [[ "$DATABASE_ZONE" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]] ||
    ! [[ "$DATA_DISK_ID" =~ ^[1-9][0-9]*$ ]] ||
    { [ "$DATABASE_SERVICE" != authentication ] && [ "$DATABASE_SERVICE" != json-keys ]; } ||
    ! [[ "$FAILED_REVISION" =~ ^[a-f0-9]{40}$ ]]; then
    printf 'Invalid interrupted first-launch recovery input.\n' >&2
    exit 65
fi

for command_name in gcloud jq; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '%s is required by first-launch recovery.\n' "$command_name" >&2
        exit 69
    fi
done

cleanup() {
    if [ -n "$RECEIPT_FILE" ]; then
        rm -f -- "$RECEIPT_FILE"
    fi
    if [ -n "$EMPTY_DATABASE_FILE" ]; then
        rm -f -- "$EMPTY_DATABASE_FILE"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

RECEIPT_FILE="$(mktemp)"
EMPTY_DATABASE_FILE="$(mktemp)"
chmod 600 "$RECEIPT_FILE" "$EMPTY_DATABASE_FILE"

if "$SCRIPT_DIR/receipt-custody.sh" latest \
    "$RECEIPT_BUCKET" "$RECEIPT_FILE" >/dev/null; then
    if ! jq -e --arg project "$PROJECT_ID" '
        .activeTfvars.workload_project_id == $project and
        .database != null and .database.hosts == null
    ' "$RECEIPT_FILE" >/dev/null; then
        printf 'A successful release receipt exists; use normal receipt rollback.\n' >&2
        exit 70
    fi
else
    RECEIPT_CODE=$?
    if [ "$RECEIPT_CODE" -ne 4 ]; then
        exit "$RECEIPT_CODE"
    fi
fi

if ! DATABASE_GROUP_JSON="$(
    gcloud compute instance-groups managed describe "$DATABASE_GROUP" \
        --project="$PROJECT_ID" \
        --zone="$DATABASE_ZONE" \
        --format=json
)"; then
    printf 'Interrupted first-launch metadata could not be inspected.\n' >&2
    exit 70
fi

IMAGE_PREFIX="$DATABASE_REGION-docker.pkg.dev/$PROJECT_ID/agora-production/service-$DATABASE_SERVICE/database@sha256:"
if [ "$(gcloud compute disks describe "agora-data-$DATABASE_SERVICE" --project="$PROJECT_ID" --zone="$DATABASE_ZONE" --format='value(id)')" != "$DATA_DISK_ID" ]; then
    printf 'The interrupted first-launch data disk does not match the protected configuration.\n' >&2
    exit 70
fi

# A previous compensation can have cleared only one host. An exact idle host
# needs no restart; this makes a retry safe after partial cleanup.
if jq -e --arg service "$DATABASE_SERVICE" '
    .allInstancesConfig.properties.metadata == {
        "agora-database-release-revision": "",
        ("agora-\($service)-database-image"): "",
        ("agora-\($service)-postgres-password-version"): "0",
        ("agora-\($service)-postgres-backup-password-version"): "0"
    }
' <<<"$DATABASE_GROUP_JSON" >/dev/null; then
    printf 'Interrupted first-launch database host is already idle.\n'
    exit 0
fi
if ! jq -e --arg service "$DATABASE_SERVICE" --arg revision "$FAILED_REVISION" --arg prefix "$IMAGE_PREFIX" '
    .allInstancesConfig.properties.metadata as $metadata |
    ($metadata | keys) == ([
        "agora-database-release-revision",
        "agora-\($service)-database-image",
        "agora-\($service)-postgres-password-version",
        "agora-\($service)-postgres-backup-password-version"
    ] | sort) and
    $metadata["agora-database-release-revision"] == $revision and
    ($metadata["agora-\($service)-database-image"] | startswith($prefix)) and
    ($metadata["agora-\($service)-database-image"] | ltrimstr($prefix) | test("^[a-f0-9]{64}$")) and
    all(["agora-\($service)-postgres-password-version", "agora-\($service)-postgres-backup-password-version"][];
        ($metadata[.] | test("^[1-9][0-9]*$")))
' <<<"$DATABASE_GROUP_JSON" >/dev/null; then
    printf 'Live database metadata is not the exact interrupted first-launch state.\n' >&2
    exit 70
fi

printf 'null\n' >"$EMPTY_DATABASE_FILE"
"$SCRIPT_DIR/restore-database-release.sh" \
    "$PROJECT_ID" "$DATABASE_ZONE" "$DATABASE_SERVICE" "$DATA_DISK_ID" "$EMPTY_DATABASE_FILE"

printf 'Interrupted first-launch database metadata cleared.\n'
