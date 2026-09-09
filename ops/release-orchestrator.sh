#!/bin/bash

# Execute the compiler-selected service rollout and compensate on failure.
# First launch and configuration maintenance include both services; routine
# image releases include exactly one, with no cross-service deployment order.
# Usage: release-orchestrator.sh <driver> <compiled-release.json>

set -euo pipefail

if [ "$#" -ne 2 ] || [ ! -x "$1" ]; then
    printf 'Usage: %s <executable-driver> <compiled-release.json>\n' "$0" >&2
    exit 64
fi

DRIVER="$1"
RELEASE_FILE="$2"
if ! jq --exit-status '
    (.mode == "service" and (.services == ["json_keys"] or .services == ["authentication"])) or
    ((.mode == "first-launch" or .mode == "maintenance") and .services == ["json_keys", "authentication"])
' "${RELEASE_FILE}" >/dev/null; then
    printf 'Compiled release scope is invalid.\n' >&2
    exit 65
fi
JSON_SELECTED="$(jq '.services | index("json_keys") != null' "${RELEASE_FILE}")"
AUTHENTICATION_SELECTED="$(jq '.services | index("authentication") != null' "${RELEASE_FILE}")"
printf 'Deployment scope: %s\n' "$(jq -r '.mode + " (" + (.services | join(", ")) + ")"' "${RELEASE_FILE}")"
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
    case "${step}" in
        json-*) [ "${JSON_SELECTED}" = true ] || continue ;;
        authentication-*) [ "${AUTHENTICATION_SELECTED}" = true ] || continue ;;
    esac
    run_step "${step}"
done

printf 'Production release completed and its immutable receipt is durable.\n'
