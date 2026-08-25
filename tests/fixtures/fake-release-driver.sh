#!/bin/bash

set -euo pipefail

printf '%s\n' "$1" >>"${RELEASE_TEST_LOG:?}"
if [ "$1" = "${RELEASE_TEST_FAIL_STEP:-}" ]; then
    exit "${RELEASE_TEST_FAIL_CODE:-42}"
fi
