#!/bin/sh

# Call the service's health RPC with this job's identity token. The token and
# the response never leave this one-shot job.
set +x
set -eu

# During a planned downtime the service answers only its liveness ping, so the check waits: clearing
# the downtime changes this job's token, and that deploy runs it. RFC 3339 UTC times sort as strings.
skip_if_started() {
    if [ -n "${DOWNTIME_START:-}" ] && expr "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \>= "${DOWNTIME_START}" >/dev/null; then
        printf 'Planned downtime started; GenAI health is checked once it is cleared.\n'
        exit 0
    fi
}
skip_if_started

IDENTITY_TOKEN="$(wget -q -T 10 -O - --header='Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${GENAI_URL:?}")"
test -n "${IDENTITY_TOKEN}"
export IDENTITY_TOKEN

# A fresh invoker grant takes a minute or two to apply, so the check retries for two minutes.
# grpcurl exits with 64 plus the gRPC status code, which names a failure without the response.
attempt=1
# Header expansion keeps the token out of the command-line arguments.
# shellcheck disable=SC2016
until grpcurl -connect-timeout 10 -max-time 15 -max-msg-sz 4096 -expand-headers -H 'Authorization: Bearer ${IDENTITY_TOKEN}' -d '{}' "${GENAI_URL#https://}:443" anovel.genai.v0.StatusService/Status >/dev/null 2>&1; do
    code=$?
    # A check that began just before the downtime fails once the service stops.
    skip_if_started
    if [ "${attempt}" -ge 12 ]; then
        printf 'GenAI status call failed: grpcurl exited with %s.\n' "${code}"
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 10
done
printf 'GenAI application health passed.\n'
