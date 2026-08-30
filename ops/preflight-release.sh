#!/bin/bash

# Validate live, read-only prerequisites before image promotion or any workload
# mutation. Secret payloads are never requested; only exact numeric version
# state is checked. Foundation-owned quota preferences must be fully granted.
# Usage: preflight-release.sh <compiled-release.json>

set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s <compiled-release.json>\n' "$0" >&2
    exit 64
fi

RELEASE_FILE="$1"
SCRATCH_DIRECTORY="$(mktemp -d)"
trap 'rm -rf -- "${SCRATCH_DIRECTORY}"' EXIT

for command in gcloud jq; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        printf 'Required release preflight tooling is unavailable.\n' >&2
        exit 69
    fi
done

if ! jq --exit-status '
    .schemaVersion == 1 and
    (.action == "deploy" or .action == "rollback") and
    (.cloud.managementProjectId | test("^[a-z][a-z0-9-]{4,28}[a-z0-9]$")) and
    (.cloud.workloadProjectId | test("^[a-z][a-z0-9-]{4,28}[a-z0-9]$")) and
    (.cloud.region | test("^[a-z]+-[a-z]+[0-9]+$")) and
    # Only rollback to the pre-first-release state has no secret consumers.
    (
      (.action == "deploy" and (.cloud.secretVersions | length) == 7) or
      (.action == "rollback" and
        ((.cloud.secretVersions | length) == 0 or (.cloud.secretVersions | length) == 7))
    ) and
    all(.cloud.secretVersions[];
      (.[0] | test("^production-[a-z0-9-]+$")) and
      (.[1] | type == "number" and . >= 1 and floor == .)
    )
' "${RELEASE_FILE}" >/dev/null; then
    printf 'Compiled release preflight inventory is invalid.\n' >&2
    exit 65
fi

MANAGEMENT_PROJECT_ID="$(jq --raw-output '.cloud.managementProjectId' "${RELEASE_FILE}")"
WORKLOAD_PROJECT_ID="$(jq --raw-output '.cloud.workloadProjectId' "${RELEASE_FILE}")"
REGION="$(jq --raw-output '.cloud.region' "${RELEASE_FILE}")"

while IFS=$'\t' read -r SECRET_ID VERSION; do
    if [ "$(
        gcloud secrets versions describe "${VERSION}" \
            --secret="${SECRET_ID}" \
            --project="${MANAGEMENT_PROJECT_ID}" \
            --format='value(state)' 2>/dev/null || true
    )" != "ENABLED" ]; then
        printf 'A required numeric Secret Manager version is not enabled.\n' >&2
        exit 70
    fi
done < <(jq --raw-output '.cloud.secretVersions[] | @tsv' "${RELEASE_FILE}")

QUOTAS_FILE="${SCRATCH_DIRECTORY}/quota-preferences.json"
if ! gcloud quotas preferences list \
    --project="${WORKLOAD_PROJECT_ID}" \
    --format=json >"${QUOTAS_FILE}" 2>/dev/null; then
    printf 'Cloud quota preferences could not be inspected.\n' >&2
    exit 70
fi

if ! jq --exit-status \
    --arg region "${REGION}" \
    --argjson expected "$(jq '.cloud.quotaExpectations' "${RELEASE_FILE}")" '
      [ .[] | select(
          .justification == "Agora production cost ceiling; changes require reviewed infrastructure code." and
          .dimensions.region == $region
        ) ] as $preferences |
      ($preferences | length == 3) and
      ([$preferences[] | select(.service == "run.googleapis.com")] | length == 2) and
      ([$preferences[] | select(.service == "compute.googleapis.com")] | length == 1) and
      all($preferences[];
        # The API may omit this default-false field after reconciliation.
        .reconciling != true and
        (.quotaConfig.preferredValue | tonumber) == (.quotaConfig.grantedValue | tonumber)
      ) and
      ([$preferences[] | select(.service == "run.googleapis.com") | (.quotaConfig.preferredValue | tonumber)] | sort) ==
        ([$expected.cloud_run_cpu_millicpu, $expected.cloud_run_memory_bytes] | sort) and
      ([$preferences[] | select(.service == "compute.googleapis.com") | (.quotaConfig.preferredValue | tonumber)]) ==
        [$expected.compute_cpu]
    ' "${QUOTAS_FILE}" >/dev/null; then
    printf 'Production quota preferences are missing, pending, or not fully granted.\n' >&2
    exit 70
fi

printf 'Live secret-version and quota preflight passed.\n'
