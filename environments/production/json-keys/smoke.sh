#!/bin/sh

# Call the service's health RPC with this job's identity token. The token and
# the response never leave this one-shot job.
set +x
set -eu

IDENTITY_TOKEN="$(wget -q -T 10 -O - --header='Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${JSON_KEYS_URL:?}")"
test -n "${IDENTITY_TOKEN}"
export IDENTITY_TOKEN

# Header expansion keeps the token out of the command-line arguments.
# shellcheck disable=SC2016
grpcurl -connect-timeout 10 -max-time 30 -max-msg-sz 4096 -expand-headers -H 'Authorization: Bearer ${IDENTITY_TOKEN}' -d '{}' "${JSON_KEYS_URL#https://}:443" anovel.jsonkeys.v2.StatusService/Status >/dev/null 2>&1
printf 'JSON Keys application health passed.\n'
