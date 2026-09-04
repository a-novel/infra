#!/bin/bash

# Clear only release metadata left by an interrupted first production launch.
# Usage: recover-first-launch.sh <receipt-bucket> <project> <zone> <failed-revision>

set -euo pipefail

if [ "$#" -ne 4 ]; then
    printf 'Usage: %s <receipt-bucket> <project> <zone> <failed-revision>\n' "$0" >&2
    exit 64
fi

RECEIPT_BUCKET="$1"
PROJECT_ID="$2"
DATABASE_ZONE="$3"
FAILED_REVISION="$4"
DATABASE_GROUP='agora-database'
DATABASE_REGION="${DATABASE_ZONE%-*}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RECEIPT_FILE=''
EMPTY_DATABASE_FILE=''

if ! [[ "$RECEIPT_BUCKET" =~ ^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$ ]] ||
    ! [[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    ! [[ "$DATABASE_ZONE" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]] ||
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
    printf 'A successful release receipt exists; use normal receipt rollback.\n' >&2
    exit 70
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

JSON_KEYS_IMAGE_PREFIX="$DATABASE_REGION-docker.pkg.dev/$PROJECT_ID/agora-production/service-json-keys/database@sha256:"
AUTHENTICATION_IMAGE_PREFIX="$DATABASE_REGION-docker.pkg.dev/$PROJECT_ID/agora-production/service-authentication/database@sha256:"

if ! jq --exit-status \
    --arg revision "$FAILED_REVISION" \
    --arg json_keys_prefix "$JSON_KEYS_IMAGE_PREFIX" \
    --arg authentication_prefix "$AUTHENTICATION_IMAGE_PREFIX" '
      def exact_image($value; $prefix):
        ($value | type) == "string" and
        ($value | startswith($prefix)) and
        (($value | ltrimstr($prefix)) | test("^[a-f0-9]{64}$"));

      (.allInstancesConfig.properties.metadata // null) as $metadata
      | ($metadata | type) == "object" and
        ($metadata | keys) == [
          "agora-authentication-database-image",
          "agora-authentication-postgres-backup-password-version",
          "agora-authentication-postgres-password-version",
          "agora-database-release-revision",
          "agora-json-keys-database-image",
          "agora-json-keys-postgres-backup-password-version",
          "agora-json-keys-postgres-password-version"
        ] and
        $metadata["agora-database-release-revision"] == $revision and
        exact_image($metadata["agora-json-keys-database-image"]; $json_keys_prefix) and
        exact_image($metadata["agora-authentication-database-image"]; $authentication_prefix) and
        all(
          [
            "agora-authentication-postgres-backup-password-version",
            "agora-authentication-postgres-password-version",
            "agora-json-keys-postgres-backup-password-version",
            "agora-json-keys-postgres-password-version"
          ][];
          ($metadata[.] | type) == "string" and
          ($metadata[.] | test("^[1-9][0-9]*$"))
        )
    ' <<<"$DATABASE_GROUP_JSON" >/dev/null; then
    printf 'Live database metadata is not the exact interrupted first-launch state.\n' >&2
    exit 70
fi

printf 'null\n' >"$EMPTY_DATABASE_FILE"
"$SCRIPT_DIR/restore-database-release.sh" \
    "$PROJECT_ID" "$DATABASE_ZONE" "$EMPTY_DATABASE_FILE"

printf 'Interrupted first-launch database metadata cleared.\n'
