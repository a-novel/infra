#!/bin/bash

# Google Cloud implementation of the selected release state machine. All mutable
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
# Bind each plan and apply to this invocation's compiler-selected scope.
# Other callers, such as PR assessment, inspect the full resource graph.
RELEASE_PLAN_SERVICES="$(jq --compact-output '.services' "${RELEASE_FILE}")"
export RELEASE_PLAN_SERVICES
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
    local service="$1"
    jq --join-output --compact-output --sort-keys --arg key "${service}" '
      .currentDatabase as $database |
      ($key | gsub("_"; "-")) as $service |
      (if $key == "json_keys" then "jsonKeys" else "authentication" end) as $prefix |
      {
        "agora-database-release-revision": ($database.hosts[$key].releaseRevision // ""),
        ("agora-\($service)-database-image"): ($database[$prefix + "Image"] // ""),
        ("agora-\($service)-postgres-password-version"): (($database[$prefix + "PasswordVersion"] // 0) | tostring),
        ("agora-\($service)-postgres-backup-password-version"): (($database[$prefix + "BackupPasswordVersion"] // 0) | tostring)
      }
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
    jq '.database = .previousDatabase | .imageManifest = .previousManifest' "${RELEASE_FILE}" >"${rollback_release}"
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
        for service in $(jq -r '.services[]' "${RELEASE_FILE}"); do
            disk_id="$(jq -r --arg service "${service}" '.cloud.databaseHosts[$service].data_disk_id' "${RELEASE_FILE}")"
            expected="$(expected_database_metadata_sha256 "${service}")"
            "${SCRIPT_DIR}/prepare-database-change.sh" "${PROJECT_ID}" "${DATABASE_ZONE}" \
                "${service//_/-}" "${disk_id}" "${COMMIT}" \
                "${RELEASE_DIRECTORY}/database-change-${service}.json" "${expected}"
        done
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
    plan)
        # Reject effective HCL changes outside the selected service before the
        # database restart. Preview later phases too; their plans are never applied.
        if jq --exit-status '.mode == "service"' "${RELEASE_FILE}" >/dev/null; then
            for phase in active rollback; do
                code=0
                TOFU_VAR_FILE="${RELEASE_DIRECTORY}/${phase}.tfvars.json" \
                    "${SCRIPT_DIR}/tofu-gate.sh" assess release "${STATE_BUCKET}" || code=$?
                case "${code}" in
                    0 | 2 | 3) ;; # Deletion approval is checked on each actual saved plan.
                    *) exit "${code}" ;;
                esac
            done
        fi
        "${SCRIPT_DIR}/create-reviewed-plan.sh" release "${STATE_BUCKET}" "${COMMIT}" \
            "$(plan_id 1)" "${RELEASE_DIRECTORY}/candidate.tfvars.json"
        ;;
    candidate)
        "${SCRIPT_DIR}/apply-reviewed-plan.sh" release "${STATE_BUCKET}" "${COMMIT}" \
            "$(plan_id 1)" "${RELEASE_DIRECTORY}/candidate.tfvars.json"
        ;;
    database)
        for service in $(jq -r '.services[]' "${RELEASE_FILE}"); do
            if jq -e --arg service "${service}" '.currentDatabase.hosts[$service] == .database.hosts[$service]' "${RELEASE_FILE}" >/dev/null; then
                printf '%s database is unchanged; restart skipped.\n' "${service}"
                continue
            fi
            mapfile -t database < <(jq -r --arg service "${service}" '
                .database as $database |
                (if $service == "json_keys" then "jsonKeys" else "authentication" end) as $prefix |
                [$database.hosts[$service].dataDiskId, $database.hosts[$service].releaseRevision,
                 $database[$prefix + "Image"], ($database[$prefix + "PasswordVersion"] | tostring),
                 ($database[$prefix + "BackupPasswordVersion"] | tostring)][]' "${RELEASE_FILE}")
            # Record before the first write, including partially failed restarts.
            touch "${RELEASE_DIRECTORY}/database-mutated-${service}"
            DATABASE_CHANGE_PROOF="${RELEASE_DIRECTORY}/database-change-${service}.json" \
                "${SCRIPT_DIR}/deploy-database-release.sh" "${PROJECT_ID}" "${DATABASE_ZONE}" "${service//_/-}" "${database[@]}"
        done
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
        for service in $(jq -r '.services[]' "${RELEASE_FILE}"); do
            case "${service}" in json_keys) operation=JsonKeys ;; authentication) operation=Authentication ;; esac
            EXECUTION="$(run_job "agora-postgres-backup-${service//_/-}")"
            update_operation ".executions.postgresBackup${operation} = \$value" "${EXECUTION}"
            EXECUTION="$(run_job "agora-postgres-restore-${service//_/-}")"
            update_operation ".executions.postgresRestore${operation} = \$value" "${EXECUTION}"
        done
        EXECUTION="$(run_job agora-postgres-backup-monitor)"
        update_operation '.executions.postgresBackupMonitor = $value' "${EXECUTION}"
        ;;
    authentication-initialization)
        EXECUTION="$(
            "${SCRIPT_DIR}/await-auth-initialization.sh" \
                "${PROJECT_ID}" "${REGION}" "${RECEIPT_BUCKET}" "${COMMIT}" \
                "$(jq -r '.cloud.databaseHosts.authentication.data_disk_id' "${RELEASE_FILE}")"
        )"
        update_operation '.initialization = $value' "${EXECUTION}"
        ;;
    json-smoke)
        JSON_REVISION="$(jq --raw-output '.revisions.jsonKeys' "${RELEASE_FILE}")"
        if ! revision_ready "${JSON_REVISION}"; then
            printf 'The private JSON Keys candidate did not become Ready.\n' >&2
            exit 70
        fi
        STATUS_FILE="$(mktemp "${RELEASE_DIRECTORY}/json-smoke.XXXXXX")"
        JOB_FILE="$(mktemp "${RELEASE_DIRECTORY}/json-smoke-job.XXXXXX")"
        trap 'rm -f -- "${STATUS_FILE}" "${JOB_FILE}"' EXIT
        gcloud run services describe "${JSON_KEYS_SERVICE}" --project="${PROJECT_ID}" \
            --region="${REGION}" --format=json >"${STATUS_FILE}"
        gcloud run jobs describe agora-json-keys-smoke --project="${PROJECT_ID}" \
            --region="${REGION}" --format=json >"${JOB_FILE}"
        # The exact job must call this candidate, not the currently serving revision.
        if ! jq --exit-status --arg revision "${JSON_REVISION}" --slurpfile job "${JOB_FILE}" \
            --slurpfile release "${RELEASE_FILE}" '
            .status as $status |
            $job[0].spec.template.spec.template.spec as $spec |
            $spec.containers as $containers |
            ($containers[0].env | map({key: .name, value: .value}) | from_entries) as $env |
            ($status.url | test("^https://[a-z0-9.-]+\\.run\\.app$")) and
            any($status.traffic[]?; .tag == "candidate" and .revisionName == $revision and .url == $env.JSON_KEYS_CANDIDATE) and
            $env.JSON_KEYS_AUDIENCE == $status.url and
            $spec.serviceAccountName == ("agora-json-keys@" + $release[0].cloud.workloadProjectId + ".iam.gserviceaccount.com") and
            ($containers | length == 1) and
            $containers[0].image == ([$release[0].images[] | select(.component == "service-json-keys" and .slot == "grpc") | .promoted] | first)
          ' "${STATUS_FILE}" >/dev/null 2>&1; then
            printf 'JSON Keys smoke job does not match the exact private candidate.\n' >&2
            exit 70
        fi
        EXECUTION="$(run_job agora-json-keys-smoke)"
        update_operation '.executions.jsonKeysSmoke = $value' "${EXECUTION}"
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
        # A database restart can leave discarded connections in a live peer's
        # pool. Retry only a validated dependency-down response from this exact
        # candidate: at most 3 requests and 2 waits (55 seconds of network/wait time).
        for ((HEALTH_ATTEMPT = 1; HEALTH_ATTEMPT <= 3; HEALTH_ATTEMPT++)); do
            if ! HTTP_STATUS="$(curl --silent --proto '=https' --tlsv1.2 \
                --connect-timeout 5 --max-time 15 --max-filesize 4096 \
                --header 'Accept: application/json' \
                --output "${HEALTH_FILE}" --write-out '%{http_code}' \
                "${CANDIDATE_URL}/v2/healthcheck")"; then
                printf 'Authentication smoke failed: HTTPS request failed or exceeded its limits.\n' >&2
                exit 70
            fi
            if [ "${HTTP_STATUS}" != 200 ]; then
                if [[ "${HTTP_STATUS}" =~ ^[0-9]{3}$ ]]; then
                    printf 'Authentication smoke: endpoint returned HTTP %s.\n' "${HTTP_STATUS}" >&2
                else
                    printf 'Authentication smoke failed: unexpected HTTP status.\n' >&2
                fi
                # A failed dependency returns 503 with the same bounded status schema.
                if [ "${HTTP_STATUS}" != 503 ]; then
                    exit 70
                fi
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
            if jq --exit-status 'all(.[]; .status == "up")' "${HEALTH_FILE}" >/dev/null; then
                if [ "${HTTP_STATUS}" != 200 ]; then
                    exit 70
                fi
                break
            fi
            # Emit only fixed component names and enum values, never response text.
            jq --raw-output '
                . as $health | ["api:jsonKeys", "client:postgres", "client:smtp"][]
                | "Authentication health: " + . + "=" +
                    (if $health[.].status == "up" then "up" else "down" end)
              ' "${HEALTH_FILE}" >&2
            if [ "${HEALTH_ATTEMPT}" -eq 3 ]; then
                printf 'Authentication smoke failed: a declared dependency is down after three checks.\n' >&2
                exit 70
            fi
            printf 'Authentication dependency down; retrying the same candidate in five seconds (%s/3).\n' "${HEALTH_ATTEMPT}" >&2
            sleep 5
        done
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
        if jq -e '.mode == "database-rebuild"' "${RELEASE_FILE}" >/dev/null; then
            # A deleted shared database is not a valid compensation target.
            # Stop only the new hosts, keep their disks and Cloud Run resources,
            # and do not publish a fictitious successful rollback receipt.
            printf 'null\n' >"${RELEASE_DIRECTORY}/empty-database.json"
            for service in $(jq -r '.services[]' "${RELEASE_FILE}"); do
                [ -f "${RELEASE_DIRECTORY}/database-mutated-${service}" ] || continue
                disk_id="$(jq -r --arg service "${service}" '.cloud.databaseHosts[$service].data_disk_id' "${RELEASE_FILE}")"
                "${SCRIPT_DIR}/restore-database-release.sh" "${PROJECT_ID}" "${DATABASE_ZONE}" "${service//_/-}" "${disk_id}" "${RELEASE_DIRECTORY}/empty-database.json"
            done
            exit 0
        fi
        if jq --exit-status '.application_release != null' \
            "${RELEASE_DIRECTORY}/rollback.tfvars.json" >/dev/null; then
            if jq --exit-status '.services | index("authentication") != null' "${RELEASE_FILE}" >/dev/null; then
                shift_traffic "${AUTHENTICATION_SERVICE}" \
                    "$(jq --raw-output '.application_release.authentication.active_revision' "${RELEASE_DIRECTORY}/rollback.tfvars.json")"
            fi
            if jq --exit-status '.services | index("json_keys") != null' "${RELEASE_FILE}" >/dev/null; then
                shift_traffic "${JSON_KEYS_SERVICE}" \
                    "$(jq --raw-output '.application_release.json_keys.active_revision' "${RELEASE_DIRECTORY}/rollback.tfvars.json")"
            fi
        fi
        apply_tfvars "${RELEASE_DIRECTORY}/rollback.tfvars.json" 3
        "${SCRIPT_DIR}/config-custody.sh" publish \
            "${STATE_BUCKET}" release "${RELEASE_DIRECTORY}/rollback.tfvars.json" \
            "${RUN_ID}" "$((RUN_ATTEMPT * 10 + 3))"
        jq '.previousDatabase' "${RELEASE_FILE}" \
            >"${RELEASE_DIRECTORY}/previous-database.json"
        chmod 600 "${RELEASE_DIRECTORY}/previous-database.json"
        for service in $(jq -r '.services[]' "${RELEASE_FILE}"); do
            if jq -e --arg service "${service}" '
                if .action == "rollback" then .currentDatabase.hosts[$service] == .previousDatabase.hosts[$service]
                else .database.hosts[$service] == .previousDatabase.hosts[$service] end
            ' "${RELEASE_FILE}" >/dev/null; then continue; fi
            if [ "$(jq -r '.action' "${RELEASE_FILE}")" != rollback ] &&
                [ ! -f "${RELEASE_DIRECTORY}/database-mutated-${service}" ]; then continue; fi
            disk_id="$(jq -r --arg service "${service}" '.cloud.databaseHosts[$service].data_disk_id' "${RELEASE_FILE}")"
            "${SCRIPT_DIR}/restore-database-release.sh" "${PROJECT_ID}" "${DATABASE_ZONE}" "${service//_/-}" "${disk_id}" "${RELEASE_DIRECTORY}/previous-database.json"
        done
        write_rollback_receipt
        ;;
    *)
        printf 'Unknown release state-machine step.\n' >&2
        exit 64
        ;;
esac
