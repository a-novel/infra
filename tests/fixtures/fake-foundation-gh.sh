#!/bin/bash

# Provides repository coordinates and captures protected foundation configuration.

set -euo pipefail

CALLS_FILE="${FAKE_FOUNDATION_CALLS:?FAKE_FOUNDATION_CALLS is required}"
SECRETS_FILE="${FAKE_FOUNDATION_SECRETS:?FAKE_FOUNDATION_SECRETS is required}"

printf '%s\n' "$*" >>"$CALLS_FILE"

if [ "${1:-}" = api ] &&
    [ "${2:-}" = repos/a-novel/infra/commits/master ]; then
    printf '%s\n' "${FAKE_FOUNDATION_SHA:-1234567890abcdef1234567890abcdef12345678}"
    exit 0
fi

case "${1:-}:${2:-}:${3:-}" in
    variable:get:GCP_MANAGEMENT_PROJECT_ID)
        printf '%s\n' management-project-prod
        ;;
    variable:get:GCP_BACKUP_BUCKET)
        printf '%s\n' management-project-prod-123456789012-backups
        ;;
    api:repos/a-novel/infra/environments/production-foundation:)
        jq -n '{
          name: "production-foundation",
          deployment_branch_policy: {
            protected_branches: true,
            custom_branch_policies: false
          },
          protection_rules: [{type: "required_reviewers"}]
        }'
        ;;
    secret:set:FOUNDATION_TFVARS_JSON)
        printf '%s\t' "$*" >>"$SECRETS_FILE"
        jq --compact-output . >>"$SECRETS_FILE"
        ;;
    *)
        exit 64
        ;;
esac
