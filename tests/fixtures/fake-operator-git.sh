#!/bin/bash

# Supplies a clean checkout for bootstrap custody tests.

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
        printf '%s\n' "${FAKE_GIT_SHA:?FAKE_GIT_SHA is required}"
        ;;
    *) exit 64 ;;
esac
