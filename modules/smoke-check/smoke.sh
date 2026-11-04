#!/bin/sh

# The health check every service shares. The cluster's smoke Jobs and health CronJobs call each
# service at its in-cluster address, over TLS. The token never reaches the logs, and reaches a command
# line only for BusyBox wget.
#
#   SERVICE_URL         the service's URL, https://<host>:<port>.
#   PROTOCOL            grpc, which calls STATUS_RPC, or http, which reads HEALTH_PATH, and fails on
#                       an error status.
#   SERVICE_TOKEN_PATH  the file the kubelet projects a service token into, which the check sends.
#   PUBLIC              true for an http endpoint anyone may read, which then receives no token.
#   SSL_CERT_FILE       the services CA, which grpcurl and BusyBox wget verify the service against.
#   DOWNTIME_START      the planned downtime's start, from which the check is skipped.
#
# The script is a container's argument, where Kubernetes turns `$$` into `$`: it holds none.
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

SERVICE_TOKEN=
if [ -n "${SERVICE_TOKEN_PATH:-}" ]; then
    SERVICE_TOKEN="$(cat "${SERVICE_TOKEN_PATH}")"
elif [ "${PUBLIC:-}" != true ]; then
    printf 'Set SERVICE_TOKEN_PATH, or PUBLIC=true for an endpoint anyone may read.\n' >&2
    exit 2
fi
export SERVICE_TOKEN
answer="${TMPDIR:-/tmp}/health-answer"
: >"${answer}"

# grpcurl exits with 64 plus the gRPC status code, and BusyBox wget with 1 on an HTTP error status.
# The service token goes in the header golib reads.
check() {
    case "${PROTOCOL:?}" in
    grpc)
        # Header expansion keeps the token out of the command-line arguments.
        # shellcheck disable=SC2016
        grpcurl -cacert "${SSL_CERT_FILE:?}" -connect-timeout 10 -max-time 15 -max-msg-sz 4096 -expand-headers -H 'X-Service-Authorization: ${SERVICE_TOKEN}' -d '{}' "${SERVICE_URL#https://}" "${STATUS_RPC:?}" >/dev/null 2>&1
        ;;
    http)
        # The services' images carry only BusyBox wget, which takes headers as arguments, readable
        # only by the pod's own processes. Its TLS client reads SSL_CERT_FILE. Authentication's
        # health endpoint answers 503 while a dependency is down. A public endpoint gets no token.
        wget -q -T 15 -O "${answer}" ${SERVICE_TOKEN:+--header "X-Service-Authorization: ${SERVICE_TOKEN}"} "${SERVICE_URL}${HEALTH_PATH:?}"
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

# A rollout's pods, certificates and network policies take a moment to settle, so the check retries
# for two minutes, every five seconds.
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
