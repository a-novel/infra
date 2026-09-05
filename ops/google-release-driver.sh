#!/bin/bash

# Google Cloud implementation of the fixed release state machine. All mutable
# values come from compile-release.mjs private files; the driver never reads or
# prints secret payloads.
# Usage: google-release-driver.sh <state-machine-step|rollback>

# jq programs deliberately keep `$value` single-quoted for jq, not the shell.
# shellcheck disable=SC2016

set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s <release-step|rollback>\n' "$0" >&2
    exit 64
fi

STEP="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIRECTORY="${RELEASE_DIRECTORY:?RELEASE_DIRECTORY is required}"
STATE_BUCKET="${STATE_BUCKET:?STATE_BUCKET is required}"
RECEIPT_BUCKET="${RECEIPT_BUCKET:?RECEIPT_BUCKET is required}"
RELEASE_FILE="${RELEASE_DIRECTORY}/release.json"
OPERATIONS_FILE="${RELEASE_DIRECTORY}/operations.json"
PROJECT_ID="$(jq --raw-output '.cloud.workloadProjectId' "${RELEASE_FILE}")"
REGION="$(jq --raw-output '.cloud.region' "${RELEASE_FILE}")"
DATABASE_ZONE="$(jq --raw-output '.cloud.databaseZone' "${RELEASE_FILE}")"
COMMIT="$(jq --raw-output '.commit' "${RELEASE_FILE}")"
RUN_ID="$(jq --raw-output '.runId' "${RELEASE_FILE}")"
RUN_ATTEMPT="$(jq --raw-output '.runAttempt' "${RELEASE_FILE}")"
# These names are the fixed OpenTofu resource contract. Keep traffic and
# candidate inspection aligned with application.tf rather than deriving names
# from image-family keys.
AUTHENTICATION_SERVICE='agora-authentication-rest'
JSON_KEYS_SERVICE='agora-json-keys-grpc'

if [ "${COMMIT}" != "${GITHUB_SHA:?GITHUB_SHA is required}" ] ||
    [ "${RUN_ID}" != "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}" ] ||
    [ "${RUN_ATTEMPT}" != "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}" ]; then
    printf 'Compiled release identity differs from this protected workflow run.\n' >&2
    exit 65
fi

plan_id() {
    local slot="$1"
    printf '%s-%s\n' "${RUN_ID}" "$((RUN_ATTEMPT * 10 + slot))"
}

apply_tfvars() {
    local file="$1"
    local slot="$2"
    local id=""
    id="$(plan_id "${slot}")"
    "${SCRIPT_DIR}/create-reviewed-plan.sh" \
        release "${STATE_BUCKET}" "${COMMIT}" "${id}" "${file}"
    "${SCRIPT_DIR}/apply-reviewed-plan.sh" \
        release "${STATE_BUCKET}" "${COMMIT}" "${id}" "${file}"
}

update_operation() {
    local jq_filter="$1"
    local value="$2"
    local temporary=""
    temporary="$(mktemp "${RELEASE_DIRECTORY}/operations.XXXXXX")"
    jq --arg value "${value}" "${jq_filter}" "${OPERATIONS_FILE}" >"${temporary}"
    chmod 600 "${temporary}"
    mv -- "${temporary}" "${OPERATIONS_FILE}"
}

run_job() {
    local job="$1"
    local attempt=0
    local authorization_attempts=43
    local completed=false
    local dispatch_error=""
    local execution=""
    local poll_seconds=10

    dispatch_error="$(mktemp "${RELEASE_DIRECTORY}/job-dispatch.XXXXXX")"
    for ((attempt = 1; attempt <= authorization_attempts; attempt++)); do
        if execution="$(
            gcloud run jobs execute "${job}" \
                --project="${PROJECT_ID}" \
                --region="${REGION}" \
                --wait \
                --quiet \
                --format='value(metadata.name)' 2>"${dispatch_error}"
        )"; then
            completed=true
            break
        fi
        # An explicit run.jobs.run denial precedes execution and is safe to
        # retry while the job's authorization tag propagates.
        if ! grep -Eiq \
            "run\.jobs\.run.*denied|PERMISSION_DENIED.*run\.jobs\.run|permission: run\.jobs\.run" \
            "${dispatch_error}"; then
            printf 'Cloud Run job %s failed:\n' "${job}" >&2
            cat "${dispatch_error}" >&2
            rm -f -- "${dispatch_error}"
            return 70
        fi
        if [ "${attempt}" -eq 1 ]; then
            printf 'Waiting for tag-based Cloud Run authorization on %s.\n' "${job}" >&2
        fi
        if [ "${attempt}" -lt "${authorization_attempts}" ]; then
            sleep "${poll_seconds}"
        fi
    done
    if [ "${completed}" != true ]; then
        printf 'Cloud Run did not authorize %s within seven minutes.\n' "${job}" >&2
        cat "${dispatch_error}" >&2
        rm -f -- "${dispatch_error}"
        return 70
    fi
    rm -f -- "${dispatch_error}"

    execution="${execution##*/}"
    if ! [[ "${execution}" =~ ^${job}-[a-z0-9]+$ ]]; then
        printf 'A required release job returned an invalid execution identity.\n' >&2
        return 70
    fi
    printf '%s\n' "${execution}"
}

expected_database_metadata_sha256() {
    jq --join-output --compact-output --sort-keys '
      # Preflight compares live metadata with the latest successful state. A
      # manual rollback can target an older, different database contract.
      .currentDatabase as $database
      | if $database == null then
          {
            "agora-authentication-database-image": "",
            "agora-authentication-postgres-backup-password-version": "0",
            "agora-authentication-postgres-password-version": "0",
            "agora-database-release-revision": "",
            "agora-json-keys-database-image": "",
            "agora-json-keys-postgres-backup-password-version": "0",
            "agora-json-keys-postgres-password-version": "0"
          }
        else
          {
            "agora-authentication-database-image": $database.authenticationImage,
            "agora-authentication-postgres-backup-password-version": ($database.authenticationBackupPasswordVersion | tostring),
            "agora-authentication-postgres-password-version": ($database.authenticationPasswordVersion | tostring),
            "agora-database-release-revision": $database.releaseRevision,
            "agora-json-keys-database-image": $database.jsonKeysImage,
            "agora-json-keys-postgres-backup-password-version": ($database.jsonKeysBackupPasswordVersion | tostring),
            "agora-json-keys-postgres-password-version": ($database.jsonKeysPasswordVersion | tostring)
          }
        end
    ' "${RELEASE_FILE}" | sha256sum | cut -d ' ' -f 1
}

revision_ready() {
    local revision="$1"
    local status_file=""
    status_file="$(mktemp "${RELEASE_DIRECTORY}/revision.XXXXXX")"
    if ! gcloud run revisions describe "${revision}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --format=json >"${status_file}" 2>/dev/null ||
        ! jq --exit-status \
            'any(.status.conditions[]?; .type == "Ready" and .status == "True")' \
            "${status_file}" >/dev/null; then
        rm -f -- "${status_file}"
        return 1
    fi
    rm -f -- "${status_file}"
}

shift_traffic() {
    local service="$1"
    local revision="$2"
    local status_file=""
    if ! gcloud run services update-traffic "${service}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --to-revisions="${revision}=100" \
        --quiet >/dev/null 2>&1; then
        printf 'Cloud Run traffic could not be shifted.\n' >&2
        return 70
    fi
    status_file="$(mktemp "${RELEASE_DIRECTORY}/traffic.XXXXXX")"
    if ! gcloud run services describe "${service}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --format=json >"${status_file}" 2>/dev/null ||
        ! jq --exit-status --arg revision "${revision}" '
            [.. | objects | select(
              ((.revisionName? == $revision) or (.revision? == $revision)) and
              .percent? == 100
            )] | length >= 1
          ' "${status_file}" >/dev/null; then
        rm -f -- "${status_file}"
        printf 'Cloud Run did not confirm the exact 100%% traffic target.\n' >&2
        return 70
    fi
    rm -f -- "${status_file}"
}

authentication_url() {
    local tag="$1"
    local status_file=""
    status_file="$(mktemp "${RELEASE_DIRECTORY}/service.XXXXXX")"
    gcloud run services describe "${AUTHENTICATION_SERVICE}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --format=json >"${status_file}" 2>/dev/null
    jq --exit-status --raw-output --arg tag "${tag}" '
        [.. | objects | select(.tag? == $tag) | (.url? // .uri? // empty)]
        | first
      ' "${status_file}"
    rm -f -- "${status_file}"
}

write_rollback_receipt() {
    local rollback_release="${RELEASE_DIRECTORY}/rollback-release.json"
    local rollback_operations="${RELEASE_DIRECTORY}/rollback-operations.json"
    local rollback_receipt="${RELEASE_DIRECTORY}/rollback-receipt.json"
    jq '.database = .previousDatabase' "${RELEASE_FILE}" >"${rollback_release}"
    jq -n '
      {
        executions: {
          jsonKeysMigrations: null,
          jsonKeysRotation: null,
          authenticationMigrations: null,
          postgresBackupJsonKeys: null,
          postgresBackupAuthentication: null,
          postgresRestoreJsonKeys: null,
          postgresRestoreAuthentication: null,
          postgresBackupMonitor: null
        },
        initialization: null,
        health: {jsonKeys: "not-run", authentication: "not-run"}
      }
    ' >"${rollback_operations}"
    chmod 600 "${rollback_release}" "${rollback_operations}"
    "${SCRIPT_DIR}/build-receipt.mjs" rollback \
        "${rollback_release}" "${RELEASE_DIRECTORY}/rollback.tfvars.json" \
        "${rollback_operations}" "${rollback_receipt}"
    "${SCRIPT_DIR}/receipt-custody.sh" publish \
        "${RECEIPT_BUCKET}" "${rollback_receipt}" "${RUN_ID}" "${RUN_ATTEMPT}"
}

case "${STEP}" in
    preflight)
        if jq --exit-status '.previousDatabase == null' "${RELEASE_FILE}" >/dev/null; then
            # The first rollout may need to delete every just-created runtime
            # during compensation, so that possibility is approved up front.
            "${SCRIPT_DIR}/verify-deletion-label.sh" \
                "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" "${COMMIT}" >/dev/null
        fi
        "${SCRIPT_DIR}/preflight-release.sh" "${RELEASE_FILE}"
        EXPECTED_DATABASE_METADATA_SHA256="$(expected_database_metadata_sha256)"
        "${SCRIPT_DIR}/prepare-database-change.sh" \
            "${PROJECT_ID}" "${DATABASE_ZONE}" "${COMMIT}" \
            "${RELEASE_DIRECTORY}/database-change-proof.json" \
            "${EXPECTED_DATABASE_METADATA_SHA256}"
        jq -n '
          {
            executions: {
              jsonKeysMigrations: null,
              jsonKeysRotation: null,
              authenticationMigrations: null,
              postgresBackupJsonKeys: null,
              postgresBackupAuthentication: null,
              postgresRestoreJsonKeys: null,
              postgresRestoreAuthentication: null,
              postgresBackupMonitor: null
            },
            initialization: null,
            health: {jsonKeys: "not-run", authentication: "not-run"}
          }
        ' >"${OPERATIONS_FILE}"
        chmod 600 "${OPERATIONS_FILE}"
        ;;
    promote)
        "${SCRIPT_DIR}/promote-release-images.sh" "${RELEASE_FILE}"
        ;;
    candidate)
        apply_tfvars "${RELEASE_DIRECTORY}/candidate.tfvars.json" 1
        ;;
    database)
        if jq --exit-status \
            '.previousDatabase != null and .database == .previousDatabase' \
            "${RELEASE_FILE}" >/dev/null; then
            printf 'Database release metadata is unchanged; restart skipped.\n'
            exit 0
        fi
        mapfile -t database < <(
            jq --raw-output '.database | [
              .releaseRevision,
              .jsonKeysImage,
              .authenticationImage,
              (.jsonKeysPasswordVersion | tostring),
              (.authenticationPasswordVersion | tostring),
              (.jsonKeysBackupPasswordVersion | tostring),
              (.authenticationBackupPasswordVersion | tostring)
            ][]' "${RELEASE_FILE}"
        )
        DATABASE_CHANGE_PROOF="${RELEASE_DIRECTORY}/database-change-proof.json" \
            "${SCRIPT_DIR}/deploy-database-release.sh" \
            "${PROJECT_ID}" "${DATABASE_ZONE}" "${database[@]}"
        ;;
    json-migrations)
        EXECUTION="$(run_job agora-json-keys-migrations)"
        update_operation '.executions.jsonKeysMigrations = $value' "${EXECUTION}"
        ;;
    json-rotation)
        EXECUTION="$(run_job agora-json-keys-rotatekeys)"
        update_operation '.executions.jsonKeysRotation = $value' "${EXECUTION}"
        ;;
    authentication-migrations)
        EXECUTION="$(run_job agora-authentication-migrations)"
        update_operation '.executions.authenticationMigrations = $value' "${EXECUTION}"
        ;;
    recovery-verification)
        EXECUTION="$(run_job agora-postgres-backup-json-keys)"
        update_operation '.executions.postgresBackupJsonKeys = $value' "${EXECUTION}"
        EXECUTION="$(run_job agora-postgres-backup-authentication)"
        update_operation '.executions.postgresBackupAuthentication = $value' "${EXECUTION}"
        EXECUTION="$(run_job agora-postgres-restore-json-keys)"
        update_operation '.executions.postgresRestoreJsonKeys = $value' "${EXECUTION}"
        EXECUTION="$(run_job agora-postgres-restore-authentication)"
        update_operation '.executions.postgresRestoreAuthentication = $value' "${EXECUTION}"
        EXECUTION="$(run_job agora-postgres-backup-monitor)"
        update_operation '.executions.postgresBackupMonitor = $value' "${EXECUTION}"
        ;;
    authentication-initialization)
        EXECUTION="$(
            "${SCRIPT_DIR}/await-auth-initialization.sh" \
                "${PROJECT_ID}" "${REGION}" "${RECEIPT_BUCKET}" "${COMMIT}"
        )"
        update_operation '.initialization = $value' "${EXECUTION}"
        ;;
    json-smoke)
        JSON_REVISION="$(jq --raw-output '.revisions.jsonKeys' "${RELEASE_FILE}")"
        if ! revision_ready "${JSON_REVISION}"; then
            printf 'The private JSON Keys candidate did not become Ready.\n' >&2
            exit 70
        fi
        update_operation '.health.jsonKeys = $value' passed
        ;;
    authentication-smoke)
        AUTH_REVISION="$(jq --raw-output '.revisions.authentication' "${RELEASE_FILE}")"
        CANDIDATE_TAG="$(jq --raw-output '.candidateTag' "${RELEASE_FILE}")"
        if ! revision_ready "${AUTH_REVISION}"; then
            printf 'Authentication smoke failed: candidate revision is not Ready.\n' >&2
            exit 70
        fi
        if ! CANDIDATE_URL="$(authentication_url "${CANDIDATE_TAG}")" ||
            ! [[ "${CANDIDATE_URL}" =~ ^https://[a-z0-9.-]+\.run\.app$ ]]; then
            printf 'Authentication smoke failed: candidate URL could not be resolved.\n' >&2
            exit 70
        fi
        HEALTH_FILE="$(mktemp "${RELEASE_DIRECTORY}/health.XXXXXX")"
        trap 'rm -f -- "${HEALTH_FILE}"' EXIT
        if ! HTTP_STATUS="$(curl --silent --proto '=https' --tlsv1.2 \
            --connect-timeout 5 --max-time 15 --max-filesize 4096 \
            --header 'Accept: application/json' \
            --output "${HEALTH_FILE}" --write-out '%{http_code}' \
            "${CANDIDATE_URL}/v2/healthcheck")"; then
            printf 'Authentication smoke failed: HTTPS request failed or exceeded its limits.\n' >&2
            exit 70
        fi
        if [ "${HTTP_STATUS}" != 200 ]; then
            printf 'Authentication smoke failed: endpoint did not return HTTP 200.\n' >&2
            exit 70
        fi
        if ! jq --slurp --exit-status '
            length == 1 and (.[0] |
                type == "object" and
                keys == ["api:jsonKeys", "client:postgres", "client:smtp"] and
                all(.[]; type == "object" and keys == ["status"] and
                    (.status == "up" or .status == "down")))
          ' "${HEALTH_FILE}" >/dev/null 2>&1; then
            printf 'Authentication smoke failed: unexpected health response schema.\n' >&2
            exit 70
        fi
        if ! jq --exit-status 'all(.[]; .status == "up")' "${HEALTH_FILE}" >/dev/null; then
            # Emit only fixed component names and enum values, never response text.
            jq --raw-output '
                . as $health | ["api:jsonKeys", "client:postgres", "client:smtp"][]
                | "Authentication health: " + . + "=" +
                    (if $health[.].status == "up" then "up" else "down" end)
              ' "${HEALTH_FILE}" >&2
            printf 'Authentication smoke failed: a declared dependency is down.\n' >&2
            exit 70
        fi
        rm -f -- "${HEALTH_FILE}"
        trap - EXIT
        update_operation '.health.authentication = $value' passed
        ;;
    json-traffic)
        shift_traffic "${JSON_KEYS_SERVICE}" \
            "$(jq --raw-output '.revisions.jsonKeys' "${RELEASE_FILE}")"
        ;;
    authentication-traffic)
        shift_traffic "${AUTHENTICATION_SERVICE}" \
            "$(jq --raw-output '.revisions.authentication' "${RELEASE_FILE}")"
        ;;
    active)
        apply_tfvars "${RELEASE_DIRECTORY}/active.tfvars.json" 2
        "${SCRIPT_DIR}/config-custody.sh" publish \
            "${STATE_BUCKET}" release "${RELEASE_DIRECTORY}/active.tfvars.json" \
            "${RUN_ID}" "$((RUN_ATTEMPT * 10 + 2))"
        ;;
    receipt)
        RECEIPT_FILE="${RELEASE_DIRECTORY}/receipt.json"
        "${SCRIPT_DIR}/promote-release-images.sh" "${RELEASE_FILE}" "${RUN_ID}"
        "${SCRIPT_DIR}/build-receipt.mjs" deployment \
            "${RELEASE_FILE}" "${RELEASE_DIRECTORY}/active.tfvars.json" \
            "${OPERATIONS_FILE}" "${RECEIPT_FILE}"
        "${SCRIPT_DIR}/receipt-custody.sh" publish \
            "${RECEIPT_BUCKET}" "${RECEIPT_FILE}" "${RUN_ID}" "${RUN_ATTEMPT}"
        ;;
    rollback)
        if jq --exit-status '.application_release != null' \
            "${RELEASE_DIRECTORY}/rollback.tfvars.json" >/dev/null; then
            shift_traffic "${AUTHENTICATION_SERVICE}" \
                "$(jq --raw-output '.application_release.authentication.active_revision' "${RELEASE_DIRECTORY}/rollback.tfvars.json")"
            shift_traffic "${JSON_KEYS_SERVICE}" \
                "$(jq --raw-output '.application_release.json_keys.active_revision' "${RELEASE_DIRECTORY}/rollback.tfvars.json")"
        fi
        apply_tfvars "${RELEASE_DIRECTORY}/rollback.tfvars.json" 3
        "${SCRIPT_DIR}/config-custody.sh" publish \
            "${STATE_BUCKET}" release "${RELEASE_DIRECTORY}/rollback.tfvars.json" \
            "${RUN_ID}" "$((RUN_ATTEMPT * 10 + 3))"
        jq '.previousDatabase' "${RELEASE_FILE}" \
            >"${RELEASE_DIRECTORY}/previous-database.json"
        chmod 600 "${RELEASE_DIRECTORY}/previous-database.json"
        "${SCRIPT_DIR}/restore-database-release.sh" \
            "${PROJECT_ID}" "${DATABASE_ZONE}" \
            "${RELEASE_DIRECTORY}/previous-database.json"
        write_rollback_receipt
        ;;
    *)
        printf 'Unknown release state-machine step.\n' >&2
        exit 64
        ;;
esac
