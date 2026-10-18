#!/bin/sh

# The health check every service shares. Smoke jobs call a gRPC service's Status RPC from inside the
# VPC, and the deploy and drift workflows read Authentication's HTTP health endpoint. The token never
# reaches the command line or the logs.
#
#   SERVICE_URL     the service's URL.
#   PROTOCOL        grpc, which calls STATUS_RPC, or http, which reads HEALTH_PATH and needs every
#                   dependency it lists up. http needs curl and jq.
#   IDENTITY_TOKEN  an ID token the service admits; by default the metadata server issues one.
#   DOWNTIME_START  the planned downtime's start, from which the check is skipped.
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

if [ -z "${IDENTITY_TOKEN:-}" ]; then
    IDENTITY_TOKEN="$(wget -q -T 10 -O - --header='Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${SERVICE_URL:?}")"
fi
test -n "${IDENTITY_TOKEN}"
export IDENTITY_TOKEN
answer="${TMPDIR:-/tmp}/health-answer"
: >"${answer}"

# grpcurl exits with 64 plus the gRPC status code; curl exits with 22 on an HTTP error status.
check() {
    case "${PROTOCOL:?}" in
    grpc)
        # Header expansion keeps the token out of the command-line arguments.
        # shellcheck disable=SC2016
        grpcurl -connect-timeout 10 -max-time 15 -max-msg-sz 4096 -expand-headers -H 'Authorization: Bearer ${IDENTITY_TOKEN}' -d '{}' "${SERVICE_URL#https://}:443" "${STATUS_RPC:?}" >/dev/null 2>&1
        ;;
    http)
        printf 'header = "Authorization: Bearer %s"\n' "${IDENTITY_TOKEN}" |
            curl -sS --fail-with-body --max-time 15 -K - -o "${answer}" "${SERVICE_URL}${HEALTH_PATH:?}" &&
            jq -e 'length > 0 and all(.[]; .status == "up")' "${answer}" >/dev/null
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

# A fresh invoker grant takes a minute or two to apply, so the check retries for two minutes.
attempt=1
until check; do
    code=$?
    # A check that began just before the downtime fails once the service stops.
    skip_if_started
    if [ "${attempt}" -ge 12 ]; then
        printf 'Health check failed after %s attempts, the last exiting with %s.\n' "${attempt}" "${code}"
        show_answer
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 10
done
show_answer
printf 'Health check passed.\n'
