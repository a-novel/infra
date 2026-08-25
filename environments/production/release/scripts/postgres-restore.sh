#!/bin/bash

# Restores only the newest committed archive into a fresh local PostgreSQL
# cluster, then runs the hardcoded integrity contract for the owning service.

set -euo pipefail

umask 077

BACKUP_MOUNT=/backups
WORKSPACE=/workspace
LOCAL_DUMP="${WORKSPACE}/database.dump"
PGDATA="${WORKSPACE}/pgdata"
PGSOCKET=/var/run/postgresql
POSTGRES_PID=""

cleanup() {
    if [ -n "${POSTGRES_PID}" ] && kill -0 "${POSTGRES_PID}" 2>/dev/null; then
        gosu postgres pg_ctl --pgdata="${PGDATA}" --mode=fast --wait stop >/dev/null 2>&1 || true
        wait "${POSTGRES_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM

for variable_name in \
    DATABASE_KEY \
    DATABASE_HOST \
    DATABASE_PORT \
    DATABASE_NAME \
    DATABASE_OWNER \
    BACKUP_ROLE \
    DATABASE_IMAGE \
    EXPECTED_EXTENSIONS \
    SOURCE_PROJECT_ID; do
    if [ -z "${!variable_name:-}" ]; then
        printf 'error: missing restore configuration %s\n' "${variable_name}" >&2
        exit 1
    fi
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
    [ "${BACKUP_ROLE}" != "${DATABASE_OWNER}_backup" ]; then
    printf 'error: invalid restore configuration\n' >&2
    exit 1
fi

MANIFEST_ROOT="${BACKUP_MOUNT}/v1/${DATABASE_KEY}/attempts"
MANIFEST_FILE="$(find "${MANIFEST_ROOT}" -type f -name completed.manifest 2>/dev/null | LC_ALL=C sort | tail -n 1 || true)"

if [ -z "${MANIFEST_FILE}" ] || [ ! -r "${MANIFEST_FILE}" ] ||
    [ "$(wc -c <"${MANIFEST_FILE}")" -gt 8192 ]; then
    printf 'error: no bounded completed backup manifest exists for %s\n' "${DATABASE_KEY}" >&2
    exit 1
fi

EXPECTED_KEYS='format database_key source_project source_host source_port source_database source_owner backup_role database_image postgres_major pg_dump_version started_epoch completed_epoch dump_object dump_size_bytes dump_sha256 execution task_attempt'
mapfile -t MANIFEST_KEYS < <(sed -n 's/^\([a-z0-9_]*\)=.*$/\1/p' "${MANIFEST_FILE}")
if [ "$(wc -l <"${MANIFEST_FILE}")" -ne 18 ] ||
    [ "${#MANIFEST_KEYS[@]}" -ne 18 ] ||
    [ "${MANIFEST_KEYS[*]}" != "${EXPECTED_KEYS}" ]; then
    printf 'error: completed backup manifest has an unsupported schema\n' >&2
    exit 1
fi

manifest_value() {
    local key="$1"
    local count=""
    local value=""

    count="$(grep -c "^${key}=" "${MANIFEST_FILE}" || true)"
    value="$(sed -n "s/^${key}=//p" "${MANIFEST_FILE}")"
    if [ "${count}" -ne 1 ] || [ -z "${value}" ]; then
        return 1
    fi
    printf '%s' "${value}"
}

FORMAT="$(manifest_value format)"
MANIFEST_DATABASE_KEY="$(manifest_value database_key)"
SOURCE_PROJECT="$(manifest_value source_project)"
SOURCE_HOST="$(manifest_value source_host)"
SOURCE_PORT="$(manifest_value source_port)"
SOURCE_DATABASE="$(manifest_value source_database)"
SOURCE_OWNER="$(manifest_value source_owner)"
MANIFEST_BACKUP_ROLE="$(manifest_value backup_role)"
MANIFEST_DATABASE_IMAGE="$(manifest_value database_image)"
POSTGRES_MAJOR="$(manifest_value postgres_major)"
PG_DUMP_VERSION="$(manifest_value pg_dump_version)"
STARTED_EPOCH="$(manifest_value started_epoch)"
COMPLETED_EPOCH="$(manifest_value completed_epoch)"
DUMP_OBJECT="$(manifest_value dump_object)"
DUMP_SIZE_BYTES="$(manifest_value dump_size_bytes)"
DUMP_SHA256="$(manifest_value dump_sha256)"
EXECUTION="$(manifest_value execution)"
TASK_ATTEMPT="$(manifest_value task_attempt)"

CURRENT_MAJOR="$(pg_restore --version | sed -n 's/^pg_restore (PostgreSQL) \([0-9][0-9]*\).*/\1/p')"
MANIFEST_DIRECTORY="$(basename "$(dirname "${MANIFEST_FILE}")")"
NOW_EPOCH="$(date -u +%s)"

if [ "${FORMAT}" != 'agora-postgres-backup-v1' ] ||
    [ "${MANIFEST_DATABASE_KEY}" != "${DATABASE_KEY}" ] ||
    [ "${SOURCE_PROJECT}" != "${SOURCE_PROJECT_ID}" ] ||
    [ "${SOURCE_HOST}" != "${DATABASE_HOST}" ] ||
    [ "${SOURCE_PORT}" != "${DATABASE_PORT}" ] ||
    [ "${SOURCE_DATABASE}" != "${DATABASE_NAME}" ] ||
    [ "${SOURCE_OWNER}" != "${DATABASE_OWNER}" ] ||
    [ "${MANIFEST_BACKUP_ROLE}" != "${BACKUP_ROLE}" ] ||
    [ "${MANIFEST_DATABASE_IMAGE}" != "${DATABASE_IMAGE}" ] ||
    [ "${POSTGRES_MAJOR}" != "${CURRENT_MAJOR}" ] ||
    ! [[ "${PG_DUMP_VERSION}" =~ ^pg_dump\ \(PostgreSQL\)\ [0-9]+(\.[0-9]+)+(\ \([^=[:cntrl:]]+\))?$ ]] ||
    ! [[ "${STARTED_EPOCH}" =~ ^[0-9]+$ ]] ||
    ! [[ "${COMPLETED_EPOCH}" =~ ^[0-9]+$ ]] ||
    ! [[ "${DUMP_SIZE_BYTES}" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "${DUMP_SHA256}" =~ ^[a-f0-9]{64}$ ]] ||
    ! [[ "${EXECUTION}" =~ ^[a-z0-9-]{1,63}$ ]] ||
    ! [[ "${TASK_ATTEMPT}" =~ ^[0-9]+$ ]] ||
    [ "${COMPLETED_EPOCH}" -lt "${STARTED_EPOCH}" ] ||
    [ "${COMPLETED_EPOCH}" -gt "$((NOW_EPOCH + 300))" ] ||
    [ "$((NOW_EPOCH - COMPLETED_EPOCH))" -gt 21600 ] ||
    [ "${MANIFEST_DIRECTORY}" != "${STARTED_EPOCH}-${EXECUTION}-${TASK_ATTEMPT}" ] ||
    [ "${DUMP_OBJECT}" != "v1/${DATABASE_KEY}/attempts/${MANIFEST_DIRECTORY}/database.dump" ]; then
    printf 'error: completed backup manifest does not match the restore contract\n' >&2
    exit 1
fi

SOURCE_DUMP="${BACKUP_MOUNT}/${DUMP_OBJECT}"
if [ ! -r "${SOURCE_DUMP}" ] || [ "$(stat -c '%s' "${SOURCE_DUMP}")" != "${DUMP_SIZE_BYTES}" ]; then
    printf 'error: completed backup archive is absent or has the wrong size\n' >&2
    exit 1
fi

cp -- "${SOURCE_DUMP}" "${LOCAL_DUMP}"
chmod 0600 "${LOCAL_DUMP}"

if [ "$(sha256sum "${LOCAL_DUMP}" | awk '{print $1}')" != "${DUMP_SHA256}" ] ||
    ! pg_restore --list "${LOCAL_DUMP}" >/dev/null 2>&1; then
    printf 'error: completed backup archive failed checksum or catalog validation\n' >&2
    exit 1
fi

install -d -m 0700 -o postgres -g postgres "${PGDATA}"
export PGDATA
export POSTGRES_DB="${DATABASE_NAME}"
export POSTGRES_HOST_AUTH_METHOD=trust
export POSTGRES_INITDB_ARGS='--auth-local=trust --auth-host=reject'
export POSTGRES_USER="${DATABASE_OWNER}"

# The same database image recreates declared extensions and the owner role.
# It listens only on a local Unix socket and has no production credential.
/usr/local/bin/docker-entrypoint.sh \
    postgres \
    -c listen_addresses= \
    -c log_min_messages=panic \
    -c log_min_error_statement=panic \
    >"${WORKSPACE}/postgres.log" 2>&1 &
POSTGRES_PID="$!"

READY_DEADLINE=$((SECONDS + 120))
until pg_isready --host="${PGSOCKET}" --port=5432 --username="${DATABASE_OWNER}" --dbname="${DATABASE_NAME}" >/dev/null 2>&1; do
    if ! kill -0 "${POSTGRES_PID}" 2>/dev/null || [ "${SECONDS}" -ge "${READY_DEADLINE}" ]; then
        printf 'error: clean restore database did not become ready\n' >&2
        exit 1
    fi
    sleep 1
done

export PGDATABASE="${DATABASE_NAME}"
export PGHOST="${PGSOCKET}"
export PGPORT=5432
export PGUSER="${DATABASE_OWNER}"

if ! pg_restore \
    --exit-on-error \
    --single-transaction \
    --no-owner \
    --no-privileges \
    --dbname="${DATABASE_NAME}" \
    "${LOCAL_DUMP}" \
    >/dev/null 2>&1; then
    printf 'error: clean PostgreSQL restore failed\n' >&2
    exit 1
fi

case "${DATABASE_KEY}" in
    json-keys)
        if ! psql --no-psqlrc --set ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
DO $restore_smoke$
BEGIN
    IF to_regclass('public.keys') IS NULL OR to_regclass('public.active_keys') IS NULL THEN
        RAISE EXCEPTION 'json keys schema is incomplete';
    END IF;

    PERFORM count(*) FROM public.keys;
    PERFORM count(*) FROM public.active_keys;

    IF EXISTS (SELECT 1 FROM public.keys WHERE private_key = '') THEN
        RAISE EXCEPTION 'json keys integrity check failed';
    END IF;
END
$restore_smoke$;
SQL
        then
            printf 'error: JSON Keys restore smoke contract failed\n' >&2
            exit 1
        fi
        ;;
    authentication)
        if ! psql --no-psqlrc --set ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
DO $restore_smoke$
BEGIN
    IF to_regclass('public.credentials') IS NULL OR to_regclass('public.short_codes') IS NULL THEN
        RAISE EXCEPTION 'authentication schema is incomplete';
    END IF;

    PERFORM count(*) FROM public.credentials;
    PERFORM count(*) FROM public.short_codes;

    IF EXISTS (
        SELECT 1 FROM public.credentials
        WHERE email = '' OR role NOT IN ('auth:anon', 'auth:user', 'auth:admin', 'auth:superadmin')
    ) OR EXISTS (
        SELECT 1
        FROM public.short_codes
        WHERE deleted_at IS NULL
        GROUP BY target, usage
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'authentication integrity check failed';
    END IF;
END
$restore_smoke$;
SQL
        then
            printf 'error: Authentication restore smoke contract failed\n' >&2
            exit 1
        fi
        ;;
    *)
        printf 'error: no restore smoke contract exists for %s\n' "${DATABASE_KEY}" >&2
        exit 1
        ;;
esac

if [ "$(psql --no-psqlrc --tuples-only --no-align --quiet --command "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension" 2>/dev/null)" != "${EXPECTED_EXTENSIONS}" ] ||
    [ "$(psql --no-psqlrc --tuples-only --no-align --quiet --command "SELECT count(*) FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'public' AND NOT c.convalidated" 2>/dev/null)" != '0' ]; then
    printf 'error: restored PostgreSQL global or constraint contract failed\n' >&2
    exit 1
fi

gosu postgres pg_ctl --pgdata="${PGDATA}" --mode=fast --wait stop >/dev/null 2>&1
wait "${POSTGRES_PID}" 2>/dev/null || true
POSTGRES_PID=""

printf 'PostgreSQL restore drill passed for %s from %s (%s bytes).\n' \
    "${DATABASE_KEY}" \
    "${MANIFEST_DIRECTORY}" \
    "${DUMP_SIZE_BYTES}"
