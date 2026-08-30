#!/bin/bash

# Provides deterministic non-secret Google Cloud coordinates for foundation tests.

set -euo pipefail

CALLS_FILE="${FAKE_FOUNDATION_CALLS:?FAKE_FOUNDATION_CALLS is required}"
printf '%s\n' "$*" >>"$CALLS_FILE"

case "$*" in
    "billing projects describe management-project-prod --format=value(billingAccountName.basename())")
        printf '%s\n' ABCDEF-123456-ABCDEF
        ;;
    "config get-value account")
        printf '%s\n' operator@example.com
        ;;
    "projects describe management-project-prod --format=value(parent.type)")
        printf '%s\n' organization
        ;;
    "projects describe management-project-prod --format=value(parent.id)")
        printf '%s\n' 123456789012
        ;;
    "projects describe management-project-prod --format=value(projectNumber)")
        printf '%s\n' 123456789012
        ;;
    "projects get-iam-policy workload-project-prod --format=json")
        printf '%s\n' '{"bindings":[]}'
        ;;
    "projects add-iam-policy-binding workload-project-prod --member=user:operator@example.com --role=roles/iam.securityReviewer --condition=None --format=none")
        ;;
    *)
        exit 64
        ;;
esac
