#!/bin/bash

# Compatibility entry point for legacy release/recovery callers.
# Go owns saved-plan application and the service-root operation guard.
# Usage: apply-reviewed-plan.sh <root> <bucket> <commit> <plan-id> <tfvars>

set -euo pipefail

if [ "$#" -ne 5 ]; then
    printf 'Usage: %s <root> <bucket> <commit> <plan-id> <tfvars>\n' "$0" >&2
    exit 64
fi

exec infra custody plan apply "$2" "$1" "$3" "$4" "$5"
