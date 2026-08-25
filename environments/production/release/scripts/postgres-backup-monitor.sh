#!/bin/sh

# Checks completion-manifest freshness and retained object size without reading
# database payloads. Any failure becomes one Cloud Run failed-execution alert.

set -eu

BACKUP_MOUNT=/backups
EXPECTED_KEYS='format database_key source_project source_host source_port source_database source_owner backup_role database_image postgres_major pg_dump_version started_epoch completed_epoch dump_object dump_size_bytes dump_sha256 execution task_attempt'
SIZE_LIST=""

cleanup() {
    if [ -n "${SIZE_LIST}" ]; then
        rm -f -- "${SIZE_LIST}"
    fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM

case "${RPO_SECONDS:-}" in
    '' | *[!0-9]*)
        printf 'error: invalid backup RPO configuration\n' >&2
        exit 1
        ;;
esac
case "${STORAGE_ALERT_BYTES:-}" in
    '' | *[!0-9]*)
        printf 'error: invalid backup storage threshold\n' >&2
        exit 1
        ;;
esac
if [ -z "${DATABASE_KEYS:-}" ]; then
    printf 'error: no database backup contracts are enabled\n' >&2
    exit 1
fi

NOW_EPOCH="$(date -u +%s)"
for database_key in ${DATABASE_KEYS}; do
    case "${database_key}" in
        *[!a-z0-9-]* | '')
            printf 'error: invalid database backup key\n' >&2
            exit 1
            ;;
    esac

    manifest="$(find "${BACKUP_MOUNT}/v1/${database_key}/attempts" -type f -name completed.manifest 2>/dev/null | LC_ALL=C sort | tail -n 1 || true)"
    if [ -z "${manifest}" ] || [ ! -r "${manifest}" ] ||
        [ "$(wc -c <"${manifest}")" -gt 8192 ] || [ "$(wc -l <"${manifest}")" -ne 18 ]; then
        printf 'error: completed backup manifest is missing or invalid for %s\n' "${database_key}" >&2
        exit 1
    fi

    manifest_keys="$(sed -n 's/^\([a-z0-9_]*\)=.*$/\1/p' "${manifest}" | tr '\n' ' ')"
    if [ "${manifest_keys% }" != "${EXPECTED_KEYS}" ]; then
        printf 'error: completed backup manifest schema is invalid for %s\n' "${database_key}" >&2
        exit 1
    fi

    format="$(awk -F= '$1 == "format" { count++; value=substr($0, index($0, "=") + 1) } END { if (count != 1) exit 1; print value }' "${manifest}")"
    manifest_key="$(awk -F= '$1 == "database_key" { count++; value=substr($0, index($0, "=") + 1) } END { if (count != 1) exit 1; print value }' "${manifest}")"
    completed_epoch="$(awk -F= '$1 == "completed_epoch" { count++; value=substr($0, index($0, "=") + 1) } END { if (count != 1) exit 1; print value }' "${manifest}")"
    dump_object="$(awk -F= '$1 == "dump_object" { count++; value=substr($0, index($0, "=") + 1) } END { if (count != 1) exit 1; print value }' "${manifest}")"
    dump_size="$(awk -F= '$1 == "dump_size_bytes" { count++; value=substr($0, index($0, "=") + 1) } END { if (count != 1) exit 1; print value }' "${manifest}")"
    dump_sha="$(awk -F= '$1 == "dump_sha256" { count++; value=substr($0, index($0, "=") + 1) } END { if (count != 1) exit 1; print value }' "${manifest}")"
    manifest_directory="$(basename "$(dirname "${manifest}")")"

    case "${completed_epoch}" in '' | *[!0-9]*) exit 1 ;; esac
    case "${dump_size}" in '' | 0 | *[!0-9]*) exit 1 ;; esac
    case "${dump_sha}" in *[!a-f0-9]* | '') exit 1 ;; esac

    dump_path="${BACKUP_MOUNT}/${dump_object}"
    if [ "${format}" != 'agora-postgres-backup-v1' ] ||
        [ "${manifest_key}" != "${database_key}" ] ||
        [ "${dump_object}" != "v1/${database_key}/attempts/${manifest_directory}/database.dump" ] ||
        [ "${#dump_sha}" -ne 64 ] ||
        [ ! -r "${dump_path}" ] ||
        [ "$(stat -c '%s' "${dump_path}")" != "${dump_size}" ] ||
        [ "${completed_epoch}" -gt "$((NOW_EPOCH + 300))" ] ||
        [ "$((NOW_EPOCH - completed_epoch))" -gt "${RPO_SECONDS}" ]; then
        printf 'error: backup RPO or completion contract failed for %s\n' "${database_key}" >&2
        exit 1
    fi
done

SIZE_LIST="$(mktemp /tmp/agora-backup-sizes.XXXXXX)"
if ! find "${BACKUP_MOUNT}/v1" -type f -exec stat -c '%s' '{}' \; >"${SIZE_LIST}"; then
    printf 'error: retained backup size could not be measured\n' >&2
    exit 1
fi

TOTAL_BYTES="$(awk '{ total += $1 } END { printf "%.0f", total }' "${SIZE_LIST}")"
if [ "${TOTAL_BYTES}" -gt "${STORAGE_ALERT_BYTES}" ]; then
    printf 'error: retained backup storage crossed its cost threshold\n' >&2
    exit 1
fi

printf 'PostgreSQL backup freshness passed for %s (%s retained bytes).\n' \
    "${DATABASE_KEYS}" \
    "${TOTAL_BYTES}"
