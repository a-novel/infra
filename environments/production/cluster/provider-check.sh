#!/bin/sh

# GenAI's provider check makes one real OpenAI call through the cluster's GenAI. It submits one small
# generation, polls it until it settles, and fails unless the generation succeeds. The cluster's sweep
# checks nothing, so the polls drive the generation: a poll checks it with OpenAI once GenAI's
# CHECK_INTERVAL has passed since the last check.
#
#   SERVICE_URL         GenAI's gRPC server, as http://<host>:<port>.
#   SERVICE_TOKEN_PATH  the file the kubelet projects GenAI's service token into.
#   SUBMIT_REQUEST      the GenerationSubmit request, as JSON.
#   DOWNTIME_START      the planned downtime's start, from which the check is skipped.
#
# The script is an argument, where Kubernetes turns `$$` into `$`: it holds none.
set +x
set -eu

# During a planned downtime GenAI answers only its liveness ping. RFC 3339 UTC times sort as strings.
if [ -n "${DOWNTIME_START:-}" ] && expr "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \>= "${DOWNTIME_START}" >/dev/null; then
    printf 'Planned downtime started; no OpenAI call is checked.\n'
    exit 0
fi

SERVICE_TOKEN="$(cat "${SERVICE_TOKEN_PATH}")"
export SERVICE_TOKEN

# call sends GenAI one request and prints its answer, one field per line.
call() {
    # Header expansion keeps the token out of the command-line arguments.
    # shellcheck disable=SC2016
    grpcurl -plaintext -connect-timeout 10 -max-time 60 -expand-headers -H 'X-Service-Authorization: ${SERVICE_TOKEN}' -d "$2" "${SERVICE_URL#http://}" "anovel.genai.v0.$1"
}

# field prints one of the generation's string fields from the last answer.
field() {
    printf '%s\n' "${answer}" | sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

answer="$(call GenerationSubmitService/GenerationSubmit "${SUBMIT_REQUEST}")"
id="$(field id)"
owner="$(field ownerId)"
printf 'Submitted generation %s.\n' "${id}"

# A failed poll is tried again until the Job's deadline.
while :; do
    status="$(field status)"
    case "${status}" in
    GENERATION_STATUS_SUCCEEDED)
        printf 'Generation %s succeeded.\n' "${id}"
        exit 0
        ;;
    GENERATION_STATUS_FAILED | GENERATION_STATUS_CANCELLED)
        printf 'Generation %s settled as %s:\n%s\n' "${id}" "${status}" "${answer}"
        exit 1
        ;;
    esac
    sleep 5
    answer="$(call GenerationGetService/GenerationGet "{\"id\": \"${id}\", \"ownerId\": \"${owner}\"}")" || answer=
done
