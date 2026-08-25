#!/bin/bash

# Prepares the preserved disk and converges the two pinned PostgreSQL containers on every boot.
# Release metadata contains only immutable image references and numeric secret-version identifiers.

set -euo pipefail

umask 077

METADATA_ROOT="http://metadata.google.internal/computeMetadata/v1"
DATA_DEVICE="/dev/disk/by-id/google-agora-data"
DATA_MOUNT="/mnt/disks/agora-data"
SECRETS_DIR="/run/agora/secrets"
DOCKER_CONFIG_DIR="/run/agora/docker"
DATABASE_BRIDGE_RANGE="172.31.254.0/29"
TOKEN_CONFIG=""
SECRET_TEMP_FILES=()
DATABASE_CONTAINERS=(
    agora-postgres-json-keys
    agora-postgres-authentication
)

remove_database_secret_files() {
    rm -f -- \
        "${SECRETS_DIR}/json-keys-postgres-password" \
        "${SECRETS_DIR}/authentication-postgres-password"
}

cleanup() {
    if [ -n "${TOKEN_CONFIG}" ]; then
        rm -f -- "${TOKEN_CONFIG}"
    fi

    if [ "${#SECRET_TEMP_FILES[@]}" -gt 0 ]; then
        rm -f -- "${SECRET_TEMP_FILES[@]}"
    fi
}
trap cleanup INT EXIT

stop_database_containers() {
    local container=""

    for container in "${DATABASE_CONTAINERS[@]}"; do
        if docker container inspect "${container}" >/dev/null 2>&1; then
            docker stop --time 60 "${container}" >/dev/null || true
        fi
    done
}

remove_database_containers() {
    local container=""

    stop_database_containers
    for container in "${DATABASE_CONTAINERS[@]}"; do
        if docker container inspect "${container}" >/dev/null 2>&1; then
            docker rm "${container}" >/dev/null
        fi
    done
}

handle_failure() {
    local status="$?"

    trap - ERR
    stop_database_containers
    # Healthy containers retain their read-only bind sources for crash
    # restart. A failed convergence has no reader and keeps no final payload.
    remove_database_secret_files
    printf 'error: database convergence failed; both database containers are stopped\n' >&2
    exit "${status}"
}
trap handle_failure ERR

metadata_request() {
    curl --fail --silent --show-error \
        --connect-timeout 2 \
        --max-time 10 \
        --header "Metadata-Flavor: Google" \
        "${METADATA_ROOT}/$1"
}

attribute_get() {
    metadata_request "instance/attributes/$1"
}

require_numeric() {
    local label="$1"
    local value="$2"

    if ! [[ "${value}" =~ ^[0-9]+$ ]] || [ "${value}" -eq 0 ]; then
        printf 'error: %s must be a positive integer\n' "${label}" >&2
        exit 1
    fi
}

require_cpu() {
    local value="$1"

    if ! [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || [ "${value}" = "0" ]; then
        printf 'error: container CPU must be a positive decimal number\n' >&2
        exit 1
    fi
}

require_promoted_image() {
    local image="$1"
    local repository="$2"
    local digest=""
    local expected_prefix="${REGISTRY_HOST}/${WORKLOAD_PROJECT_ID}/agora-production/${repository}@sha256:"

    case "${image}" in
        "${expected_prefix}"*) digest="${image#"${expected_prefix}"}" ;;
        *)
            printf 'error: database image is outside the promoted repository contract\n' >&2
            exit 1
            ;;
    esac

    if ! [[ "${digest}" =~ ^[a-f0-9]{64}$ ]]; then
        printf 'error: database image must use an immutable sha256 digest\n' >&2
        exit 1
    fi
}

fetch_secret() {
    local secret_id="$1"
    local version="$2"
    local destination="$3"
    local newline_count=""
    local payload_size=""
    local temporary_file=""

    temporary_file="$(mktemp "${SECRETS_DIR}/.${secret_id}.XXXXXX")"
    SECRET_TEMP_FILES+=("${temporary_file}")

    curl --config "${TOKEN_CONFIG}" \
        --fail \
        --silent \
        --show-error \
        --retry 5 \
        --retry-all-errors \
        "https://secretmanager.googleapis.com/v1/projects/${MANAGEMENT_PROJECT_ID}/secrets/${secret_id}/versions/${version}:access" \
        | sed -n 's/.*"data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | base64 -d > "${temporary_file}"

    newline_count="$(wc -l < "${temporary_file}")"
    payload_size="$(wc -c < "${temporary_file}")"
    if [ "${newline_count}" -ne 0 ] || [ "${payload_size}" -lt 32 ] || [ "${payload_size}" -gt 128 ] || \
        ! LC_ALL=C grep -Eq '^[A-Za-z0-9_-]+$' "${temporary_file}"; then
        printf 'error: %s must be a 32-128 character URL-safe database password\n' "${secret_id}" >&2
        exit 1
    fi

    # The parent directory remains root-only on the host. The read-only bind
    # mount must also be readable by PostgreSQL inside its user namespace so a
    # pinned password version can be activated after first initialization.
    chmod 0444 "${temporary_file}"
    mv -f -- "${temporary_file}" "${destination}"
}

ensure_database_network() {
    local network_name="$1"
    local expected_subnet="$2"
    local actual_internal=""
    local actual_subnet=""

    if docker network inspect "${network_name}" >/dev/null 2>&1; then
        actual_internal="$(docker network inspect --format '{{.Internal}}' "${network_name}")"
        actual_subnet="$(docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "${network_name}")"

        if [ "${actual_internal}" != "false" ] || [ "${actual_subnet}" != "${expected_subnet}" ]; then
            docker network rm "${network_name}" >/dev/null
        fi
    fi

    if ! docker network inspect "${network_name}" >/dev/null 2>&1; then
        docker network create \
            --driver bridge \
            --subnet "${expected_subnet}" \
            "${network_name}" >/dev/null
    fi
}

configure_database_firewall() {
    local docker_chain="AGORA-DATABASE-EGRESS"
    local host_chain="AGORA-DATABASE-HOST"

    # Inbound VPC connections are forwarded through Docker's published-port
    # rules. Their replies may return, while every connection initiated by a
    # database container is rejected, including metadata and peer access.
    iptables -w -N "${docker_chain}" 2>/dev/null || true
    iptables -w -F "${docker_chain}"
    iptables -w -A "${docker_chain}" \
        -s "${DATABASE_BRIDGE_RANGE}" \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -j RETURN
    iptables -w -A "${docker_chain}" -s "${DATABASE_BRIDGE_RANGE}" -j REJECT
    while iptables -w -D DOCKER-USER -j "${docker_chain}" 2>/dev/null; do :; done
    iptables -w -I DOCKER-USER 1 -j "${docker_chain}"

    # Traffic addressed to the bridge gateway enters the host INPUT chain
    # instead of DOCKER-USER. Reject it so a database process cannot reach a
    # host daemon through that alternate path.
    iptables -w -N "${host_chain}" 2>/dev/null || true
    iptables -w -F "${host_chain}"
    iptables -w -A "${host_chain}" -s "${DATABASE_BRIDGE_RANGE}" -j REJECT
    while iptables -w -D INPUT -j "${host_chain}" 2>/dev/null; do :; done
    iptables -w -I INPUT 1 -j "${host_chain}"
}

activate_database_password() {
    local container_name="$1"
    local database_user="$2"
    local database_name="$3"

    # The payload stays inside the container: a local superuser session reads
    # the read-only file, quotes it server-side, and stores its SCRAM verifier.
    # Every statement/error/duration/audit logger is disabled for this session,
    # while client output is discarded and failures expose only a fixed label.
    if ! docker exec --interactive --user postgres \
            --env 'PGOPTIONS=-c log_statement=none -c log_min_messages=panic -c log_min_error_statement=panic -c log_min_duration_statement=-1 -c log_min_duration_sample=-1 -c log_transaction_sample_rate=0 -c log_error_verbosity=terse -c pgaudit.log=none -c auto_explain.log_min_duration=-1' \
            "${container_name}" \
            psql \
            --no-psqlrc \
            --set ON_ERROR_STOP=1 \
            --username "${database_user}" \
            --dbname "${database_name}" \
            >/dev/null 2>&1 <<'SQL'
DO $activate_password$
BEGIN
    EXECUTE format(
        'ALTER ROLE %I PASSWORD %L',
        current_user,
        pg_read_file('/run/agora-postgres-password')
    );
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'database password activation failed';
END
$activate_password$;
SQL
    then
        printf 'error: database password activation failed for %s\n' "${container_name}" >&2
        return 1
    fi
}

start_database() {
    local key="$1"
    local image="$2"
    local host_port="$3"
    local database_user="$4"
    local database_name="$5"
    local password_file="$6"
    local container_name="agora-postgres-${key}"
    local data_directory="${DATA_MOUNT}/${key}"
    local network_name="agora-database-${key}"
    local elapsed=0
    local health=""
    local running=""

    install -d -m 0700 "${data_directory}"

    if docker container inspect "${container_name}" >/dev/null 2>&1; then
        docker stop --time 60 "${container_name}" >/dev/null
        docker rm "${container_name}" >/dev/null
    fi

    # `on-failure` restarts a crashed PostgreSQL process but, unlike
    # `always`/`unless-stopped`, never starts it when Docker itself boots. The
    # metadata startup script must restore the egress-deny chains first.
    docker run --detach \
        --name "${container_name}" \
        --label "agora.component=${key}" \
        --network "${network_name}" \
        --dns 127.0.0.1 \
        --publish "${DATABASE_IP}:${host_port}:5432" \
        --restart on-failure:5 \
        --stop-timeout 60 \
        --cpus "${CONTAINER_CPU}" \
        --memory "${CONTAINER_MEMORY_MB}m" \
        --memory-swap "${CONTAINER_MEMORY_MB}m" \
        --pids-limit 512 \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        --env "POSTGRES_USER=${database_user}" \
        --env "POSTGRES_DB=${database_name}" \
        --env "POSTGRES_PASSWORD_FILE=/run/agora-postgres-password" \
        --env "POSTGRES_HOST_AUTH_METHOD=scram-sha-256" \
        --env "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=trust" \
        --mount "type=bind,source=${data_directory},target=/var/lib/postgresql" \
        --mount "type=bind,source=${password_file},target=/run/agora-postgres-password,readonly" \
        --tmpfs "/var/run/postgresql:rw,nosuid,nodev,size=16m" \
        "${image}" \
        postgres \
        -c "listen_addresses=*" \
        -c "max_connections=${MAX_CONNECTIONS}" \
        -c "password_encryption=scram-sha-256" >/dev/null

    until [ "${health}" = "healthy" ]; do
        running="$(docker inspect --format '{{.State.Running}}' "${container_name}")"
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "${container_name}")"
        if [ "${running}" != "true" ] || [ "${health}" = "unhealthy" ] || [ "${health}" = "missing" ] || [ "${elapsed}" -ge 120 ]; then
            printf 'error: %s did not become healthy within 120 seconds\n' "${container_name}" >&2
            exit 1
        fi

        elapsed=$((elapsed + 1))
        sleep 1
    done

    activate_database_password "${container_name}" "${database_user}" "${database_name}"
}

# ---- Preserved storage ----

elapsed=0
until [ -b "${DATA_DEVICE}" ]; do
    if [ "${elapsed}" -ge 60 ]; then
        printf 'error: preserved data disk did not attach within 60 seconds\n' >&2
        exit 1
    fi

    elapsed=$((elapsed + 1))
    sleep 1
done

filesystem_type="$(blkid -s TYPE -o value "${DATA_DEVICE}" 2>/dev/null || true)"
case "${filesystem_type}" in
    "")
        # A missing signature can also indicate corruption. Format only a
        # provider-created disk whose first MiB is still entirely zeroed.
        if ! cmp -n 1048576 /dev/zero "${DATA_DEVICE}" >/dev/null 2>&1; then
            printf 'error: unrecognized non-empty data disk; refusing destructive initialization\n' >&2
            exit 1
        fi
        mkfs.ext4 -F -m 1 -L agora-data "${DATA_DEVICE}" >/dev/null
        ;;
    ext4) ;;
    *)
        printf 'error: preserved data disk has unsupported filesystem %s\n' "${filesystem_type}" >&2
        exit 1
        ;;
esac

install -d -m 0750 "${DATA_MOUNT}"
if mountpoint -q "${DATA_MOUNT}"; then
    mounted_source="$(findmnt -n -o SOURCE --target "${DATA_MOUNT}")"
    if [ "$(readlink -f "${mounted_source}")" != "$(readlink -f "${DATA_DEVICE}")" ]; then
        printf 'error: data mountpoint is occupied by an unexpected device\n' >&2
        exit 1
    fi
else
    mount -o noatime,nosuid,nodev "${DATA_DEVICE}" "${DATA_MOUNT}"
fi
resize2fs "${DATA_DEVICE}" >/dev/null

# ---- Release contract ----

RELEASE_REVISION="$(attribute_get agora-database-release-revision 2>/dev/null || true)"
if [ -z "${RELEASE_REVISION}" ]; then
    # Foundation prepares and verifies storage but deliberately starts no
    # database until one complete release supplies all five non-secret fields.
    stop_database_containers
    remove_database_secret_files
    printf 'Database release metadata is absent; the private host remains idle.\n'
    exit 0
fi

if ! [[ "${RELEASE_REVISION}" =~ ^[a-f0-9]{40}$ ]]; then
    printf 'error: database release revision must be a full Git commit SHA\n' >&2
    exit 1
fi

MANAGEMENT_PROJECT_ID="$(attribute_get agora-management-project-id)"
WORKLOAD_PROJECT_ID="$(metadata_request project/project-id)"
REGISTRY_HOST="$(attribute_get agora-registry-host)"
DATABASE_IP="$(metadata_request instance/network-interfaces/0/ip)"
CONTAINER_CPU="$(attribute_get agora-database-container-cpu)"
CONTAINER_MEMORY_MB="$(attribute_get agora-database-container-memory-mb)"
MAX_CONNECTIONS="$(attribute_get agora-database-max-connections)"
JSON_KEYS_IMAGE="$(attribute_get agora-json-keys-database-image)"
AUTHENTICATION_IMAGE="$(attribute_get agora-authentication-database-image)"
JSON_KEYS_PASSWORD_VERSION="$(attribute_get agora-json-keys-postgres-password-version)"
AUTHENTICATION_PASSWORD_VERSION="$(attribute_get agora-authentication-postgres-password-version)"

require_cpu "${CONTAINER_CPU}"
require_numeric "container memory" "${CONTAINER_MEMORY_MB}"
require_numeric "maximum connections" "${MAX_CONNECTIONS}"
require_numeric "JSON Keys password version" "${JSON_KEYS_PASSWORD_VERSION}"
require_numeric "Authentication password version" "${AUTHENTICATION_PASSWORD_VERSION}"
require_promoted_image "${JSON_KEYS_IMAGE}" "service-json-keys/database"
require_promoted_image "${AUTHENTICATION_IMAGE}" "service-authentication/database"

# ---- Host-only credentials and images ----

install -d -m 0700 "${SECRETS_DIR}" "${DOCKER_CONFIG_DIR}"

TOKEN_RESPONSE="$(metadata_request instance/service-accounts/default/token)"
ACCESS_TOKEN="$(printf '%s' "${TOKEN_RESPONSE}" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
unset TOKEN_RESPONSE

if [ -z "${ACCESS_TOKEN}" ]; then
    printf 'error: metadata server returned no access token\n' >&2
    exit 1
fi

TOKEN_CONFIG="$(mktemp /run/agora/secret-manager-curl.XXXXXX)"
printf 'header = "Authorization: Bearer %s"\n' "${ACCESS_TOKEN}" > "${TOKEN_CONFIG}"
unset ACCESS_TOKEN

JSON_KEYS_PASSWORD_FILE="${SECRETS_DIR}/json-keys-postgres-password"
AUTHENTICATION_PASSWORD_FILE="${SECRETS_DIR}/authentication-postgres-password"

fetch_secret \
    production-json-keys-postgres-password \
    "${JSON_KEYS_PASSWORD_VERSION}" \
    "${JSON_KEYS_PASSWORD_FILE}"
fetch_secret \
    production-authentication-postgres-password \
    "${AUTHENTICATION_PASSWORD_VERSION}" \
    "${AUTHENTICATION_PASSWORD_FILE}"

if cmp -s "${JSON_KEYS_PASSWORD_FILE}" "${AUTHENTICATION_PASSWORD_FILE}"; then
    printf 'error: the two database passwords must be distinct\n' >&2
    exit 1
fi

# Docker invokes the standalone helper, which obtains short-lived credentials
# from the attached VM identity. This file contains only the registry hostname
# and helper name; no access token is written to disk.
printf '{"credHelpers":{"%s":"gcr"}}\n' "${REGISTRY_HOST}" > "${DOCKER_CONFIG_DIR}/config.json"
chmod 0600 "${DOCKER_CONFIG_DIR}/config.json"
export DOCKER_CONFIG="${DOCKER_CONFIG_DIR}"
docker pull --quiet "${JSON_KEYS_IMAGE}" >/dev/null
docker pull --quiet "${AUTHENTICATION_IMAGE}" >/dev/null

# Each cluster receives one container address. Separate bridges prevent direct
# peer traffic; the host firewall supplies inbound-only VPC reachability.
remove_database_containers
ensure_database_network agora-database-json-keys 172.31.254.0/30
ensure_database_network agora-database-authentication 172.31.254.4/30
configure_database_firewall

# ---- Database convergence ----

start_database \
    json-keys \
    "${JSON_KEYS_IMAGE}" \
    5432 \
    agora_json_keys \
    agora_json_keys \
    "${JSON_KEYS_PASSWORD_FILE}"
start_database \
    authentication \
    "${AUTHENTICATION_IMAGE}" \
    5433 \
    agora_authentication \
    agora_authentication \
    "${AUTHENTICATION_PASSWORD_FILE}"

printf 'Database release %s is healthy.\n' "${RELEASE_REVISION}"
