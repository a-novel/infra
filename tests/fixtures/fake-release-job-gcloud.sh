#!/bin/bash

# Emulates Cloud Run job execution for release-driver retry tests.

set -euo pipefail

printf '%s\n' "$*" >>"${RELEASE_JOB_GCLOUD_LOG}"

if [ "$1 $2 $3" != "run jobs execute" ]; then
    exit 64
fi

EXECUTE_COUNT="$(grep -Fc 'run jobs execute' "${RELEASE_JOB_GCLOUD_LOG}")"
if [ "${RELEASE_JOB_EXECUTION_FAILED}" = true ]; then
    printf 'mock execution failure: agora-json-keys-migrations-execution1\n' >&2
    exit 1
fi
if [ "${EXECUTE_COUNT}" -le "${RELEASE_JOB_DENIALS}" ]; then
    printf "ERROR: PERMISSION_DENIED: Permission 'run.jobs.run' denied on resource.\n" >&2
    exit 1
fi
printf '%s\n' 'agora-json-keys-migrations-execution1'
