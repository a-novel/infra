#!/bin/bash

# Check the deployed Authentication service and its exact declared dependency
# set without printing the service URL or response body.
# Usage: check-authentication-health.sh <foundation-config>

set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s <foundation-config>\n' "$0" >&2
    exit 64
fi

umask 077
FOUNDATION_CONFIG="$1"
SCRATCH_DIRECTORY="$(mktemp -d)"
RESPONSE_FILE="${SCRATCH_DIRECTORY}/authentication-health.json"

cleanup() {
    rm -rf -- "${SCRATCH_DIRECTORY}"
}
trap cleanup INT EXIT

for command_name in curl gcloud jq; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required by the synthetic health check.\n' "${command_name}" >&2
        exit 69
    fi
done

if [ ! -f "${FOUNDATION_CONFIG}" ] ||
    ! WORKLOAD_PROJECT="$(jq --exit-status --raw-output '.workload_project_id | select(type == "string")' "${FOUNDATION_CONFIG}")" ||
    ! REGION="$(jq --exit-status --raw-output '.region | select(type == "string")' "${FOUNDATION_CONFIG}")" ||
    ! [[ "${WORKLOAD_PROJECT}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    ! [[ "${REGION}" =~ ^[a-z]+-[a-z]+[0-9]+$ ]]; then
    printf 'The private foundation configuration has invalid service coordinates.\n' >&2
    exit 65
fi

# Read the provider-issued URL for this exact project, region, and service. A
# code-derived hostname would couple the check to Google's current URL format.
if ! SERVICE_URL="$(gcloud run services describe agora-authentication-rest \
    --project="${WORKLOAD_PROJECT}" --region="${REGION}" \
    --format='value(status.url)' --quiet 2>/dev/null)" ||
    ! [[ "${SERVICE_URL}" =~ ^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.run\.app$ ]]; then
    printf 'The Authentication service URL could not be resolved safely.\n' >&2
    exit 70
fi

# The response remains in a mode-0600 scratch directory and is deleted on every
# exit. A 4 KiB ceiling prevents an unexpected endpoint from filling the runner.
if ! HTTP_STATUS="$(curl --silent \
    --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 30 --max-filesize 4096 \
    --header 'Accept: application/json' \
    --output "${RESPONSE_FILE}" --write-out '%{http_code}' \
    "${SERVICE_URL}/v2/healthcheck")"; then
    printf 'Authentication health could not be checked.\n' >&2
    exit 70
fi

# Authentication intentionally returns JSON even when a dependency is down.
# Fail closed unless the response is 200 and contains only the three current
# contracts, each with only one healthy status field.
if [ "${HTTP_STATUS}" != 200 ] ||
    ! jq --exit-status '
      type == "object" and
      keys == ["api:jsonKeys", "client:postgres", "client:smtp"] and
      all(.[];
        type == "object" and
        keys == ["status"] and
        .status == "up"
      )
    ' "${RESPONSE_FILE}" >/dev/null; then
    printf 'Authentication or one of its declared dependencies is unhealthy.\n' >&2
    exit 70
fi

printf 'Authentication and all declared dependencies are healthy.\n'
