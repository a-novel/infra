#!/bin/sh

# The health check every service shares. Smoke jobs call a gRPC service's Status RPC from inside the
# VPC, and the deploy and drift workflows read the HTTP health endpoints of Authentication and Studio.
# On the cluster, smoke Jobs and health CronJobs call each service at its in-cluster address. The
# token never reaches the logs, and reaches a command line only for BusyBox wget on the cluster.
#
#   SERVICE_URL         the service's URL: https://… on Cloud Run, https://<host>:<port> on the
#                       cluster.
#   PROTOCOL            grpc, which calls STATUS_RPC, or http, which reads HEALTH_PATH and needs
#                       every status it reports up, nested ones included. http needs curl and jq,
#                       except on the cluster.
#   IDENTITY_TOKEN      an ID token the service admits; by default the metadata server issues one.
#   SERVICE_TOKEN_PATH  on the cluster, the file the kubelet projects a service token into, which
#                       the check sends instead of an ID token.
#   SSL_CERT_FILE       on the cluster, the services CA, which grpcurl and BusyBox wget verify the
#                       service against.
#   PUBLIC              true for an http endpoint anyone may read, which then receives no token.
#   DOWNTIME_START      the planned downtime's start, from which the check is skipped.
#
# On the cluster the script is an argument, where Kubernetes turns `$$` into `$`: it holds none.
set +x
set -eu

# During a planned downtime a service answers only its liveness ping, so the check waits: clearing
# the downtime runs it again. RFC 3339 UTC times sort as strings.
skip_if_started() {
    if [ -n "${DOWNTIME_START:-}" ] && expr "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \>= "${DOWNTIME_START}" >/dev/null; then
        printf 'Planned downtime started; health is checked once it is cleared.\n'
        exit 0
    fi
}
skip_if_started

if [ -n "${SERVICE_TOKEN_PATH:-}" ]; then
    SERVICE_TOKEN="$(cat "${SERVICE_TOKEN_PATH}")"
    export SERVICE_TOKEN
elif [ "${PUBLIC:-}" = true ]; then
    IDENTITY_TOKEN=
elif [ -z "${IDENTITY_TOKEN:-}" ]; then
    IDENTITY_TOKEN="$(wget -q -T 10 -O - --header='Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${SERVICE_URL:?}")"
    test -n "${IDENTITY_TOKEN}"
fi
export IDENTITY_TOKEN
answer="${TMPDIR:-/tmp}/health-answer"
: >"${answer}"

# grpcurl exits with 64 plus the gRPC status code; curl exits with 22 on an HTTP error status, and
# BusyBox wget with 1. On the cluster, the service token goes in the header golib reads.
check() {
    case "${PROTOCOL:?}${SERVICE_TOKEN_PATH:+-cluster}" in
    grpc)
        # Header expansion keeps the token out of the command-line arguments.
        # shellcheck disable=SC2016
        grpcurl -connect-timeout 10 -max-time 15 -max-msg-sz 4096 -expand-headers -H 'Authorization: Bearer ${IDENTITY_TOKEN}' -d '{}' "${SERVICE_URL#https://}:443" "${STATUS_RPC:?}" >/dev/null 2>&1
        ;;
    grpc-cluster)
        # shellcheck disable=SC2016
        grpcurl -cacert "${SSL_CERT_FILE:?}" -connect-timeout 10 -max-time 15 -max-msg-sz 4096 -expand-headers -H 'X-Service-Authorization: ${SERVICE_TOKEN}' -d '{}' "${SERVICE_URL#https://}" "${STATUS_RPC:?}" >/dev/null 2>&1
        ;;
    http)
        if [ -n "${IDENTITY_TOKEN}" ]; then
            printf 'header = "Authorization: Bearer %s"\n' "${IDENTITY_TOKEN}"
        fi |
            curl -sS --fail-with-body --max-time 15 -K - -o "${answer}" "${SERVICE_URL}${HEALTH_PATH:?}" &&
            jq -e '[.. | objects | select(has("status")).status] | length > 0 and all(. == "up")' "${answer}" >/dev/null
        ;;
    http-cluster)
        # The services' images carry only BusyBox wget, which takes headers as arguments, readable
        # only by the pod's own processes. Its TLS client reads SSL_CERT_FILE. Authentication's
        # health endpoint answers 503 while a dependency is down.
        wget -q -T 15 -O "${answer}" --header "X-Service-Authorization: ${SERVICE_TOKEN}" "${SERVICE_URL}${HEALTH_PATH:?}"
        ;;
    *)
        printf 'PROTOCOL must be grpc or http, not %s.\n' "${PROTOCOL}" >&2
        exit 2
        ;;
    esac
}

show_answer() {
    if [ -s "${answer}" ]; then
        cat "${answer}"
        printf '\n'
    fi
}

# A fresh invoker grant takes a minute or two to apply, so the check retries for two minutes, every
# five seconds.
deadline=$(($(date +%s) + 120))
attempt=1
until check; do
    code=$?
    # A check that began just before the downtime fails once the service stops.
    skip_if_started
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        printf 'Health check failed after %s attempts, the last exiting with %s.\n' "${attempt}" "${code}"
        show_answer
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 5
done
show_answer
printf 'Health check passed.\n'
