#!/bin/bash

# Returns deterministic repository coordinates for operator-environment tests.

set -euo pipefail

[ "$*" = "variable list --repo a-novel/infra --json name,value" ]

case "${FAKE_OPERATOR_GITHUB_MODE:-matching}" in
    matching)
        printf '%s\n' '[{"name":"GCP_MANAGEMENT_PROJECT_ID","value":"management-project-prod"},{"name":"GCP_WORKLOAD_PROJECT_ID","value":"workload-project-prod"}]'
        ;;
    mismatch)
        printf '%s\n' '[{"name":"GCP_MANAGEMENT_PROJECT_ID","value":"other-management-prod"},{"name":"GCP_WORKLOAD_PROJECT_ID","value":"workload-project-prod"}]'
        ;;
    unpublished)
        printf '%s\n' '[]'
        ;;
    *)
        exit 64
        ;;
esac
