# shellcheck shell=bash

# This fragment runs only after postgres-restore.sh has validated the selected
# archive in a clean local PostgreSQL cluster. It refuses any non-empty target,
# so a protected recovery execution cannot overwrite an existing workload.

if [ "${RECOVERY_TARGET:-false}" != true ] ||
    [ -z "${RECOVERY_PROJECT_ID:-}" ] ||
    [ "${RECOVERY_PROJECT_ID}" = "${SOURCE_PROJECT_ID}" ] ||
    [ ! -r /secrets/password ]; then
    printf 'error: invalid disposable recovery target\n' >&2
    exit 1
fi

export PGHOST="${DATABASE_HOST}"
export PGPORT="${DATABASE_PORT}"
export PGDATABASE="${DATABASE_NAME}"
export PGUSER="${DATABASE_OWNER}"
PGPASSWORD="$(</secrets/password)"
export PGPASSWORD

if [ "$(
    psql --no-psqlrc --tuples-only --no-align --quiet --command \
        "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','f')" \
        2>/dev/null
)" != 0 ]; then
    printf 'error: recovery target is not an empty disposable database\n' >&2
    exit 1
fi

if ! pg_restore \
    --exit-on-error \
    --single-transaction \
    --no-owner \
    --no-privileges \
    --dbname="${DATABASE_NAME}" \
    "${LOCAL_DUMP}" \
    >/dev/null 2>&1; then
    printf 'error: protected PostgreSQL recovery failed\n' >&2
    exit 1
fi

case "${DATABASE_KEY}" in
    json-keys)
        REQUIRED_TABLES="keys active_keys"
        ;;
    authentication)
        REQUIRED_TABLES="credentials short_codes"
        ;;
    *)
        printf 'error: no protected recovery contract exists\n' >&2
        exit 1
        ;;
esac

for table in ${REQUIRED_TABLES}; do
    if [ "$(
        psql --no-psqlrc --tuples-only --no-align --quiet \
            --command "SELECT to_regclass('public.${table}') IS NOT NULL" 2>/dev/null
    )" != t ]; then
        printf 'error: protected recovery schema smoke check failed\n' >&2
        exit 1
    fi
done

if [ "$(
    psql --no-psqlrc --tuples-only --no-align --quiet \
        --command "SELECT count(*) FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'public' AND NOT c.convalidated" \
        2>/dev/null
)" != 0 ]; then
    printf 'error: protected recovery constraint check failed\n' >&2
    exit 1
fi

unset PGPASSWORD
printf 'Protected PostgreSQL recovery passed for %s attempt %s.\n' \
    "${DATABASE_KEY}" "${RECOVERY_ATTEMPT}"
