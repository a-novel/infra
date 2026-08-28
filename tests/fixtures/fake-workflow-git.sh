#!/bin/bash

# Provides a clean exact master checkout for ops/run-workflow.sh tests.

set -euo pipefail

case "$*" in
    *' branch --show-current')
        printf '%s\n' "${FAKE_GIT_BRANCH:-master}"
        ;;
    *' status --porcelain')
        if [ "${FAKE_GIT_DIRTY:-false}" = true ]; then
            printf '%s\n' ' M docs/runbooks/README.md'
        fi
        ;;
    *' rev-parse HEAD')
        printf '%s\n' "${FAKE_WORKFLOW_SHA:?FAKE_WORKFLOW_SHA is required}"
        ;;
    *) exit 64 ;;
esac
