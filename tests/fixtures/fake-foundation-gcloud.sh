#!/bin/bash

# Provides non-secret coordinates for bootstrap custody tests.

set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_FOUNDATION_CALLS:?}"

case "$*" in
    'projects describe management-project-prod --format=value(projectNumber)')
        printf '%s\n' 123456789012
        ;;
    'config get-value account')
        printf '%s\n' operator@example.com
        ;;
    *) exit 64 ;;
esac
