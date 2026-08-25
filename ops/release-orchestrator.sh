#!/bin/bash

# Execute the fixed production dependency graph. The driver contains provider
# operations; this state machine contains only ordering and one compensation
# edge, which makes every failure boundary cheap to test without cloud access.
# Usage: release-orchestrator.sh <driver>

set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -x "$1" ]; then
    printf 'Usage: %s <executable-driver>\n' "$0" >&2
    exit 64
fi

DRIVER="$1"
MUTATED=false

compensate() {
    local failed_step="$1"
    local failed_code="$2"

    printf 'Release step %s failed; restoring the last successful receipt.\n' \
        "${failed_step}" >&2
    if ! "${DRIVER}" rollback; then
        printf 'Automatic compensation also failed; use the protected recovery runbook.\n' >&2
        exit 75
    fi
    printf 'The prior serving state was restored; migrations and data were not reversed.\n' >&2
    exit "${failed_code}"
}

run_step() {
    local step="$1"
    local code=0

    # The database image rollout is the first call that may partially mutate
    # cloud state. Mark it before entry so an interrupted restart compensates.
    if [ "${step}" = database ]; then
        MUTATED=true
    fi
    set +e
    "${DRIVER}" "${step}"
    code=$?
    set -e
    if [ "${code}" -ne 0 ]; then
        if [ "${MUTATED}" = true ]; then
            compensate "${step}" "${code}"
        fi
        exit "${code}"
    fi
}

for step in \
    preflight \
    promote \
    database \
    candidate \
    json-migrations \
    json-rotation \
    authentication-migrations \
    recovery-verification \
    authentication-initialization \
    json-smoke \
    json-traffic \
    authentication-smoke \
    authentication-traffic \
    active \
    receipt; do
    run_step "${step}"
done

printf 'Production release completed and its immutable receipt is durable.\n'
