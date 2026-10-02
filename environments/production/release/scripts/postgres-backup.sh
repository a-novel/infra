#!/bin/bash

# Creates one self-validating PostgreSQL archive in a shared ephemeral volume.
# A separate sidecar uploads the archive and, only afterwards, its completion manifest.

set -euo pipefail

umask 077

WORKSPACE=/workspace
CONTROL_DIR="${WORKSPACE}/control"
PASSWORD_FILE=/secrets/password
PGPASS_FILE="${WORKSPACE}/pgpass"
DUMP_FILE="${WORKSPACE}/database.dump"
PG_DUMP_LOG="${WORKSPACE}/pg-dump.log"
MANIFEST_FILE="${WORKSPACE}/completed.manifest"
STATUS_FILE="${WORKSPACE}/backup.status"

# The pinned uploader runs non-root. Keep the dump in the non-writable volume
# root and give the sidecar a separate write-only directory for two fixed
# completion signals; it cannot replace the archive or manifest by directory
# mutation.
chmod 0755 "${WORKSPACE}"
install -d -m 0733 "${CONTROL_DIR}"

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
on_exit() {
    local status="$?"

    trap - EXIT
    rm -f -- "${PGPASS_FILE}"
    if [ "${status}" -ne 0 ]; then
        printf 'failure\n' >"${STATUS_FILE}"
        chmod 0644 "${STATUS_FILE}"
        printf 'error: PostgreSQL backup failed for %s\n' "${DATABASE_KEY:-unknown}" >&2
    fi
    exit "${status}"
}
trap on_exit EXIT
trap 'exit 1' INT TERM

require_value() {
    if [ -z "$2" ]; then
        printf 'error: missing backup configuration %s\n' "$1" >&2
        return 1
    fi
}

for variable_name in \
    DATABASE_KEY \
    DATABASE_HOST \
    DATABASE_PORT \
    DATABASE_NAME \
    DATABASE_OWNER \
    BACKUP_ROLE \
    DATABASE_IMAGE \
    EXPECTED_EXTENSIONS \
    SOURCE_PROJECT_ID \
    CLOUD_RUN_EXECUTION \
    CLOUD_RUN_TASK_ATTEMPT; do
    require_value "${variable_name}" "${!variable_name:-}"
done

if ! [[ "${DATABASE_KEY}" =~ ^[a-z][a-z0-9-]{1,30}$ ]] ||
    ! [[ "${DATABASE_HOST}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] ||
    ! [[ "${DATABASE_PORT}" =~ ^[1-9][0-9]{2,4}$ ]] ||
    ! [[ "${DATABASE_NAME}" =~ ^[a-z][a-z0-9_]{1,62}$ ]] ||
    ! [[ "${DATABASE_OWNER}" =~ ^[a-z][a-z0-9_]{1,62}$ ]] ||
    ! [[ "${BACKUP_ROLE}" =~ ^[a-z][a-z0-9_]{1,62}$ ]] ||
    ! [[ "${DATABASE_IMAGE}" =~ @sha256:[a-f0-9]{64}$ ]] ||
    ! [[ "${EXPECTED_EXTENSIONS}" =~ ^[a-z0-9_-]+(,[a-z0-9_-]+)*$ ]] ||
    ! [[ "${SOURCE_PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
    ! [[ "${CLOUD_RUN_EXECUTION}" =~ ^[a-z0-9-]{1,63}$ ]] ||
    ! [[ "${CLOUD_RUN_TASK_ATTEMPT}" =~ ^[0-9]+$ ]] ||
    [ "${BACKUP_ROLE}" != "${DATABASE_OWNER}_backup" ]; then
    printf 'error: invalid PostgreSQL backup configuration\n' >&2
    exit 1
fi

if [ ! -r "${PASSWORD_FILE}" ] ||
    [ "$(wc -l <"${PASSWORD_FILE}")" -ne 0 ] ||
    [ "$(wc -c <"${PASSWORD_FILE}")" -lt 32 ] ||
    [ "$(wc -c <"${PASSWORD_FILE}")" -gt 128 ] ||
    ! LC_ALL=C grep -Eq '^[A-Za-z0-9_-]+$' "${PASSWORD_FILE}"; then
    printf 'error: invalid PostgreSQL backup credential\n' >&2
    exit 1
fi

{
    printf '%s:%s:%s:%s:' \
        "${DATABASE_HOST}" \
        "${DATABASE_PORT}" \
        "${DATABASE_NAME}" \
        "${BACKUP_ROLE}"
    cat "${PASSWORD_FILE}"
    printf '\n'
} >"${PGPASS_FILE}"
chmod 0600 "${PGPASS_FILE}"

export PGDATABASE="${DATABASE_NAME}"
export PGHOST="${DATABASE_HOST}"
export PGPASSFILE="${PGPASS_FILE}"
export PGPORT="${DATABASE_PORT}"
export PGSSLMODE=disable
export PGUSER="${BACKUP_ROLE}"

query_scalar() {
    psql \
        --no-psqlrc \
        --set ON_ERROR_STOP=1 \
        --tuples-only \
        --no-align \
        --quiet \
        --command "$1" \
        2>/dev/null
}

PG_DUMP_VERSION="$(pg_dump --version)"
POSTGRES_MAJOR="$(printf '%s\n' "${PG_DUMP_VERSION}" | sed -n 's/^pg_dump (PostgreSQL) \([0-9][0-9]*\).*/\1/p')"

if ! [[ "${POSTGRES_MAJOR}" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "${PG_DUMP_VERSION}" =~ ^pg_dump\ \(PostgreSQL\)\ [0-9]+(\.[0-9]+)+(\ \([^=[:cntrl:]]+\))?$ ]]; then
    printf 'error: unsupported PostgreSQL backup tool version\n' >&2
    exit 1
fi

# pg_dump excludes cluster globals. Refuse an undeclared role, database,
# tablespace, or replication slot before producing an archive that could not be
# reconstructed from the database image and this repository's role contract.
if [ "$(query_scalar 'SELECT current_database() || chr(124) || current_user')" != "${DATABASE_NAME}|${BACKUP_ROLE}" ] ||
    [ "$(query_scalar "SELECT current_setting('agora.database_image', true)")" != "${DATABASE_IMAGE}" ] ||
    [ "$(query_scalar "SELECT current_setting('server_version_num')::integer / 10000")" != "${POSTGRES_MAJOR}" ] ||
    [ "$(query_scalar "SELECT count(*) FROM pg_roles WHERE rolname !~ '^pg_' AND rolname NOT IN ('${DATABASE_OWNER}', '${BACKUP_ROLE}')")" != "0" ] ||
    [ "$(query_scalar "SELECT count(*) FROM pg_database database JOIN pg_roles owner ON owner.oid = database.datdba WHERE database.datname = '${DATABASE_NAME}' AND owner.rolname = '${DATABASE_OWNER}'")" != "1" ] ||
    [ "$(query_scalar "SELECT count(*) FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres', '${DATABASE_NAME}')")" != "0" ] ||
    [ "$(query_scalar "SELECT count(*) FROM pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global')")" != "0" ] ||
    [ "$(query_scalar 'SELECT count(*) FROM pg_replication_slots')" != "0" ] ||
    [ "$(query_scalar "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension")" != "${EXPECTED_EXTENSIONS}" ] ||
    [ "$(query_scalar "SELECT count(*) FROM pg_roles WHERE rolname = '${BACKUP_ROLE}' AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls OR NOT rolcanlogin OR NOT rolinherit OR rolconnlimit <> 2)")" != "0" ] ||
    [ "$(query_scalar "SELECT count(*) FROM pg_auth_members membership JOIN pg_roles granted_role ON granted_role.oid = membership.roleid JOIN pg_roles member_role ON member_role.oid = membership.member WHERE member_role.rolname = '${BACKUP_ROLE}' AND granted_role.rolname = 'pg_read_all_data'")" != "1" ] ||
    [ "$(query_scalar "SELECT count(*) FROM pg_auth_members membership JOIN pg_roles granted_role ON granted_role.oid = membership.roleid JOIN pg_roles member_role ON member_role.oid = membership.member WHERE member_role.rolname !~ '^pg_' AND NOT (member_role.rolname = '${BACKUP_ROLE}' AND granted_role.rolname = 'pg_read_all_data')")" != "0" ]; then
    printf 'error: PostgreSQL cluster globals differ from the declared backup contract\n' >&2
    exit 1
fi

STARTED_EPOCH="$(date -u +%s)"
ATTEMPT_ID="${STARTED_EPOCH}-${CLOUD_RUN_EXECUTION}-${CLOUD_RUN_TASK_ATTEMPT}"
ATTEMPT_PREFIX="v1/${DATABASE_KEY}/attempts/${ATTEMPT_ID}"
DUMP_OBJECT="${ATTEMPT_PREFIX}/database.dump"

if ! pg_dump \
    --format=custom \
    --compress=zstd:6 \
    --lock-wait-timeout=60s \
    --no-owner \
    --no-privileges \
    --file="${DUMP_FILE}" \
    >/dev/null 2>"${PG_DUMP_LOG}"; then
    printf 'error: pg_dump failed\n' >&2
    exit 1
fi

# Treat a warning as an incomplete recovery point. The diagnostic stays in the
# ephemeral volume because PostgreSQL messages can contain object identifiers.
if [ -s "${PG_DUMP_LOG}" ] ||
    [ ! -s "${DUMP_FILE}" ] ||
    ! pg_restore --list "${DUMP_FILE}" >/dev/null 2>&1; then
    printf 'error: PostgreSQL archive validation failed\n' >&2
    exit 1
fi
rm -f -- "${PG_DUMP_LOG}"

DUMP_SIZE_BYTES="$(wc -c <"${DUMP_FILE}")"
DUMP_SHA256="$(sha256sum "${DUMP_FILE}" | awk '{print $1}')"
COMPLETED_EPOCH="$(date -u +%s)"

if ! [[ "${DUMP_SIZE_BYTES}" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "${DUMP_SHA256}" =~ ^[a-f0-9]{64}$ ]] ||
    [ "${COMPLETED_EPOCH}" -lt "${STARTED_EPOCH}" ]; then
    printf 'error: PostgreSQL archive metadata validation failed\n' >&2
    exit 1
fi

# The fixed key order is part of the restore parser's fail-closed contract.
# Values are identifiers, timings, sizes, or hashes; no credential or row data
# is written to the manifest or logs.
{
    printf 'format=agora-postgres-backup-v1\n'
    printf 'database_key=%s\n' "${DATABASE_KEY}"
    printf 'source_project=%s\n' "${SOURCE_PROJECT_ID}"
    printf 'source_host=%s\n' "${DATABASE_HOST}"
    printf 'source_port=%s\n' "${DATABASE_PORT}"
    printf 'source_database=%s\n' "${DATABASE_NAME}"
    printf 'source_owner=%s\n' "${DATABASE_OWNER}"
    printf 'backup_role=%s\n' "${BACKUP_ROLE}"
    printf 'database_image=%s\n' "${DATABASE_IMAGE}"
    printf 'postgres_major=%s\n' "${POSTGRES_MAJOR}"
    printf 'pg_dump_version=%s\n' "${PG_DUMP_VERSION}"
    printf 'started_epoch=%s\n' "${STARTED_EPOCH}"
    printf 'completed_epoch=%s\n' "${COMPLETED_EPOCH}"
    printf 'dump_object=%s\n' "${DUMP_OBJECT}"
    printf 'dump_size_bytes=%s\n' "${DUMP_SIZE_BYTES}"
    printf 'dump_sha256=%s\n' "${DUMP_SHA256}"
    printf 'execution=%s\n' "${CLOUD_RUN_EXECUTION}"
    printf 'task_attempt=%s\n' "${CLOUD_RUN_TASK_ATTEMPT}"
} >"${MANIFEST_FILE}"

chmod 0444 "${DUMP_FILE}" "${MANIFEST_FILE}"
printf 'ready\n' >"${STATUS_FILE}"
chmod 0644 "${STATUS_FILE}"

UPLOAD_DEADLINE=$((SECONDS + 1500))
while [ "${SECONDS}" -lt "${UPLOAD_DEADLINE}" ]; do
    if [ -f "${CONTROL_DIR}/upload.ok" ]; then
        printf 'PostgreSQL backup completed for %s in %s seconds (%s bytes).\n' \
            "${DATABASE_KEY}" \
            "$((COMPLETED_EPOCH - STARTED_EPOCH))" \
            "${DUMP_SIZE_BYTES}"
        exit 0
    fi

    if [ -f "${CONTROL_DIR}/upload.failed" ]; then
        printf 'error: PostgreSQL backup upload failed\n' >&2
        exit 1
    fi

    sleep 1
done

printf 'error: PostgreSQL backup upload did not complete before its deadline\n' >&2
exit 1
