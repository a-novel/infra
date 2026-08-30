#!/bin/bash

# Validates the stable project coordinates selected by the human operator.

set -euo pipefail

usage() {
    printf 'Usage: %s [--github]\n' "$0" >&2
    exit 64
}

fail() {
    printf 'FAIL %s\n' "$1" >&2
    exit "${2:-65}"
}

is_project_id() {
    [[ "$1" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
}

CHECK_GITHUB=false
case "${1:-}" in
    '') ;;
    --github) CHECK_GITHUB=true ;;
    *) usage ;;
esac
if [ "$#" -gt 1 ]; then
    usage
fi

MANAGEMENT_PROJECT_ID="${INFRA_MANAGEMENT_PROJECT_ID:-}"
WORKLOAD_PROJECT_ID="${INFRA_WORKLOAD_PROJECT_ID:-}"

if ! is_project_id "$MANAGEMENT_PROJECT_ID"; then
    fail 'INFRA_MANAGEMENT_PROJECT_ID is missing or invalid; load the reviewed .envrc' 64
fi
if ! is_project_id "$WORKLOAD_PROJECT_ID"; then
    fail 'INFRA_WORKLOAD_PROJECT_ID is missing or invalid; load the reviewed .envrc' 64
fi
if [ "$MANAGEMENT_PROJECT_ID" = "$WORKLOAD_PROJECT_ID" ]; then
    fail 'management and workload project IDs must differ' 64
fi

if [ "$CHECK_GITHUB" = true ]; then
    for command_name in gh jq; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            fail "$command_name is required to verify published project coordinates" 69
        fi
    done

    REPOSITORY_VARIABLES="$(gh variable list --repo a-novel/infra --json name,value)"
    if ! jq --exit-status 'type == "array"' <<<"$REPOSITORY_VARIABLES" >/dev/null; then
        fail 'GitHub did not return the repository variables'
    fi

    PUBLISHED_MANAGEMENT_PROJECT_ID="$(jq --raw-output '
      [.[] | select(.name == "GCP_MANAGEMENT_PROJECT_ID") | .value]
      | if length == 0 then "" elif length == 1 then .[0] else error("duplicate") end
    ' <<<"$REPOSITORY_VARIABLES")"
    PUBLISHED_WORKLOAD_PROJECT_ID="$(jq --raw-output '
      [.[] | select(.name == "GCP_WORKLOAD_PROJECT_ID") | .value]
      | if length == 0 then "" elif length == 1 then .[0] else error("duplicate") end
    ' <<<"$REPOSITORY_VARIABLES")"

    if [ -n "$PUBLISHED_MANAGEMENT_PROJECT_ID" ] &&
        [ "$PUBLISHED_MANAGEMENT_PROJECT_ID" != "$MANAGEMENT_PROJECT_ID" ]; then
        fail 'INFRA_MANAGEMENT_PROJECT_ID does not match the published GitHub coordinate'
    fi
    if [ -n "$PUBLISHED_WORKLOAD_PROJECT_ID" ] &&
        [ "$PUBLISHED_WORKLOAD_PROJECT_ID" != "$WORKLOAD_PROJECT_ID" ]; then
        fail 'INFRA_WORKLOAD_PROJECT_ID does not match the published GitHub coordinate'
    fi

    printf 'PASS published project coordinates\n'
else
    printf 'PASS operator project coordinates\n'
fi
