#!/bin/bash

# Provides repository coordinates for foundation audit and bootstrap custody.

set -euo pipefail

CALLS_FILE="${FAKE_FOUNDATION_CALLS:?FAKE_FOUNDATION_CALLS is required}"

printf '%s\n' "$*" >>"$CALLS_FILE"

case "${1:-}:${2:-}:${3:-}" in
    api:repos/a-novel/infra/commits/master:--jq)
        printf '%s\n' "${FAKE_GIT_SHA:?}"
        ;;
    variable:get:GCP_MANAGEMENT_PROJECT_ID)
        printf '%s\n' management-project-prod
        ;;
    variable:get:GCP_BACKUP_BUCKET)
        printf '%s\n' management-project-prod-123456789012-backups
        ;;
    *)
        exit 64
        ;;
esac
