#!/bin/sh

# Uploads a validated archive before its completion manifest. The Cloud Run
# task identity has storage.objects.create and deliberately cannot read, replace,
# or delete an object in the recovery bucket.

set -eu

umask 077

WORKSPACE=/workspace
CONTROL_DIR="${WORKSPACE}/control"
STATUS_FILE="${WORKSPACE}/backup.status"
TOKEN_CONFIG=""
UPLOAD_COMPLETE=false

cleanup() {
    status="$?"

    if [ -n "${TOKEN_CONFIG}" ]; then
        rm -f -- "${TOKEN_CONFIG}"
    fi

    if [ "${status}" -ne 0 ] && [ "${UPLOAD_COMPLETE}" != true ] && [ -w "${CONTROL_DIR}" ]; then
        printf 'upload failed\n' >"${CONTROL_DIR}/upload.failed"
    fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM

case "${BACKUP_BUCKET:-}" in
    '' | *[!a-z0-9._-]*)
        printf 'error: invalid backup bucket configuration\n' >&2
        exit 1
        ;;
esac

WAIT_DEADLINE=$(( $(date -u +%s) + 1700 ))
while [ ! -f "${STATUS_FILE}" ]; do
    if [ "$(date -u +%s)" -ge "${WAIT_DEADLINE}" ]; then
        printf 'error: backup producer did not finish before its deadline\n' >&2
        exit 1
    fi
    sleep 1
done

if [ "$(cat "${STATUS_FILE}")" != 'ready' ]; then
    printf 'upload producer failed\n' >"${CONTROL_DIR}/upload.failed"
    exit 1
fi

for path in "${WORKSPACE}/database.dump" "${WORKSPACE}/completed.manifest"; do
    if [ ! -r "${path}" ] || [ ! -s "${path}" ]; then
        printf 'upload input failed\n' >"${CONTROL_DIR}/upload.failed"
        exit 1
    fi
done

manifest_value() {
    key="$1"
    value="$(sed -n "s/^${key}=//p" "${WORKSPACE}/completed.manifest")"
    count="$(grep -c "^${key}=" "${WORKSPACE}/completed.manifest" || true)"
    if [ "${count}" -ne 1 ] || [ -z "${value}" ]; then
        return 1
    fi
    printf '%s' "${value}"
}

if ! DUMP_OBJECT="$(manifest_value dump_object)"; then
    printf 'upload manifest failed\n' >"${CONTROL_DIR}/upload.failed"
    exit 1
fi
MANIFEST_OBJECT="${DUMP_OBJECT%/database.dump}/completed.manifest"

case "${DUMP_OBJECT}" in
    v1/*/attempts/*/database.dump) ;;
    *)
        printf 'upload object contract failed\n' >"${CONTROL_DIR}/upload.failed"
        exit 1
        ;;
esac

TOKEN_RESPONSE="$(curl --disable \
    --fail \
    --silent \
    --show-error \
    --connect-timeout 2 \
    --max-time 10 \
    --header 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
    2>/dev/null)"
ACCESS_TOKEN="$(printf '%s' "${TOKEN_RESPONSE}" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
unset TOKEN_RESPONSE

if [ -z "${ACCESS_TOKEN}" ]; then
    printf 'token acquisition failed\n' >"${CONTROL_DIR}/upload.failed"
    exit 1
fi

TOKEN_CONFIG="$(mktemp /tmp/agora-storage-curl.XXXXXX)"
printf 'header = "Authorization: Bearer %s"\n' "${ACCESS_TOKEN}" >"${TOKEN_CONFIG}"
unset ACCESS_TOKEN

upload_object() {
    source_file="$1"
    object_name="$2"
    content_type="$3"
    maximum_seconds="$4"

    # ifGenerationMatch=0 makes a collision fail instead of overwriting a
    # recovery point. Cloud Run retries use a new task-attempt path, so curl
    # intentionally does not retry an ambiguous create response.
    curl --disable \
        --config "${TOKEN_CONFIG}" \
        --fail \
        --silent \
        --show-error \
        --disallow-username-in-url \
        --proto '=https' \
        --tlsv1.2 \
        --connect-timeout 10 \
        --max-time "${maximum_seconds}" \
        --request POST \
        --header "Content-Type: ${content_type}" \
        --data-binary "@${source_file}" \
        --url-query 'uploadType=media' \
        --url-query "name=${object_name}" \
        --url-query 'ifGenerationMatch=0' \
        "https://storage.googleapis.com/upload/storage/v1/b/${BACKUP_BUCKET}/o" \
        >/dev/null 2>&1
}

if ! upload_object "${WORKSPACE}/database.dump" "${DUMP_OBJECT}" application/octet-stream 1200; then
    printf 'archive upload failed\n' >"${CONTROL_DIR}/upload.failed"
    exit 1
fi

# A manifest is the commit record. Its presence means the archive already
# exists and passed size, checksum, and pg_restore-list validation locally.
if ! upload_object "${WORKSPACE}/completed.manifest" "${MANIFEST_OBJECT}" text/plain 60; then
    printf 'manifest upload failed\n' >"${CONTROL_DIR}/upload.failed"
    exit 1
fi

printf 'ok\n' >"${CONTROL_DIR}/upload.ok"
UPLOAD_COMPLETE=true
